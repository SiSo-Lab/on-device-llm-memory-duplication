// SPDX-License-Identifier: GPL-2.0
/*
 * Marks every VMA of a fixed list of processes as KSM-mergeable, once.
 *
 * For each PID in target_pids, the worker calls ksm_madvise(MADV_MERGEABLE)
 * on each VMA that exists at load time and passes vma_ok(). This is the
 * per-VMA effect of prctl(PR_SET_MEMORY_MERGE, 1), but MMF_VM_MERGE_ANY is
 * not set (ksm_enable_merge_any() is not exported), so VMAs created after
 * the module is loaded are not marked. No other process is touched, and
 * the KSM scanner itself is unchanged.
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/sched/signal.h>
#include <linux/mm.h>
#include <linux/mman.h>
#include <linux/kthread.h>
#include <linux/sched/mm.h>
#include <linux/ksm.h>
#include <linux/delay.h>
#include <linux/string.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("eksm-p: PID-allowlist one-shot KSM marking (for llama app PIDs); userspace polls /sys stats");

static bool verbose = true;
module_param(verbose, bool, 0644);
MODULE_PARM_DESC(verbose, "Verbose per-task logging");

static int hold_sec = 60;
module_param(hold_sec, int, 0644);
MODULE_PARM_DESC(hold_sec, "Seconds to stay alive after marking (for userspace to observe KSM stats)");

static int max_tasks = 0;
module_param(max_tasks, int, 0644);
MODULE_PARM_DESC(max_tasks, "Max number of tasks to scan (0 = unlimited)");

/* The measurement scripts load the module with both filters disabled. */
static bool skip_file_vma = true;
module_param(skip_file_vma, bool, 0644);
MODULE_PARM_DESC(skip_file_vma, "Skip file-backed VMAs (vma->vm_file)");

static bool only_private_anon = true;
module_param(only_private_anon, bool, 0644);
MODULE_PARM_DESC(only_private_anon, "Only apply to private anonymous VMAs");

static char target_pids[256] = "";
module_param_string(target_pids, target_pids, sizeof(target_pids), 0644);
MODULE_PARM_DESC(target_pids, "Comma-separated PID allowlist (only these PIDs will be scanned). Empty => do nothing.");

#define EKSM_P_MAX_PIDS 8

static struct task_struct *worker;

static bool vma_ok(struct vm_area_struct *vma)
{
	if (!vma)
		return false;

	if (vma->vm_flags & (VM_IO | VM_PFNMAP | VM_HUGETLB))
		return false;

	if (skip_file_vma && vma->vm_file)
		return false;

	if (only_private_anon) {
		if (vma->vm_file)
			return false;
		if (vma->vm_flags & VM_SHARED)
			return false;
	}

	if (!(vma->vm_flags & VM_READ))
		return false;

	return true;
}

static int parse_target_pids(int out[EKSM_P_MAX_PIDS])
{
	char buf[sizeof(target_pids)];
	char *p, *tok;
	int n = 0;

	if (target_pids[0] == '\0')
		return 0;

	strscpy(buf, target_pids, sizeof(buf));
	p = buf;

	while ((tok = strsep(&p, ",")) != NULL) {
		int pid;

		while (*tok == ' ' || *tok == '\t')
			tok++;
		if (*tok == '\0')
			continue;

		if (kstrtoint(tok, 10, &pid) != 0)
			continue;
		if (pid <= 0)
			continue;

		out[n++] = pid;
		if (n >= EKSM_P_MAX_PIDS)
			break;
	}

	return n;
}

static void eksm_p_scan_one_task(struct task_struct *task,
				 int *tasks_with_mm,
				 int *tasks_applied,
				 long *vmas_visited,
				 long *vmas_applied,
				 int *last_ret)
{
	struct mm_struct *mm;
	struct vm_area_struct *vma;
	bool applied_this_task = false;

	mm = get_task_mm(task);
	if (!mm) {
		if (verbose)
			pr_info("eksm-p: pid=%d comm=%s skip (no mm)\n",
				task->pid, task->comm);
		return;
	}

	(*tasks_with_mm)++;

	if (verbose)
		pr_info("eksm-p: pid=%d comm=%s scan\n", task->pid, task->comm);

	/*
	 * Borrow the target mm so that ksm_madvise() registers it with ksmd
	 * through current->mm. vm_flags is updated without vma_start_write().
	 */
	kthread_use_mm(mm);
	mmap_write_lock(current->mm);

	VMA_ITERATOR(vmi, current->mm, 0);
	for_each_vma(vmi, vma) {
		int ret;

		(*vmas_visited)++;

		if (!vma_ok(vma))
			continue;

		ret = ksm_madvise(vma,
				  vma->vm_start,
				  vma->vm_end,
				  MADV_MERGEABLE,
				  (unsigned long *)&vma->vm_flags);
		*last_ret = ret;
		if (ret == 0) {
			(*vmas_applied)++;
			applied_this_task = true;
		}
	}

	mmap_write_unlock(current->mm);
	kthread_unuse_mm(mm);

	if (applied_this_task) {
		(*tasks_applied)++;
		pr_info("eksm-p: pid=%d comm=%s done (total_vmas_visited=%ld total_vmas_applied=%ld last_ret=%d)\n",
			task->pid, task->comm, *vmas_visited, *vmas_applied, *last_ret);
	}

	mmput(mm);
}

static int eksm_p_worker_fn(void *arg)
{
	int tasks_seen = 0;
	int tasks_with_mm = 0;
	int tasks_applied = 0;
	long vmas_visited = 0;
	long vmas_applied = 0;
	int last_ret = 0;

	int pids[EKSM_P_MAX_PIDS];
	int npids, i;

	pr_info("eksm-p: ===== PID-allowlist one-shot scan start =====\n");
	pr_info("eksm-p: target_pids=\"%s\" skip_file_vma=%d only_private_anon=%d\n",
		target_pids, skip_file_vma, only_private_anon);

	npids = parse_target_pids(pids);
	if (npids == 0) {
		pr_info("eksm-p: no target_pids provided -> do nothing, exiting\n");
		return 0;
	}

	for (i = 0; i < npids; i++) {
		struct task_struct *task;

		if (max_tasks > 0 && tasks_seen >= max_tasks)
			break;

		rcu_read_lock();
		task = find_task_by_vpid(pids[i]);
		if (task)
			get_task_struct(task);
		rcu_read_unlock();

		if (!task) {
			if (verbose)
				pr_info("eksm-p: pid=%d not found (skip)\n", pids[i]);
			continue;
		}

		tasks_seen++;
		eksm_p_scan_one_task(task, &tasks_with_mm, &tasks_applied,
				     &vmas_visited, &vmas_applied, &last_ret);

		put_task_struct(task);
	}

	pr_info("eksm-p: PASS_DONE tasks_seen=%d tasks_with_mm=%d tasks_applied(at_least_1_vma)=%d vmas_visited=%ld vmas_applied=%ld last_ret=%d\n",
		tasks_seen, tasks_with_mm, tasks_applied, vmas_visited, vmas_applied, last_ret);

	if (hold_sec > 0) {
		int j;
		for (j = 0; j < hold_sec; j++) {
			if (kthread_should_stop())
				break;
			if (j == 0 || (j % 5) == 0)
				pr_info("eksm-p: holding... (%d/%d sec)\n", j, hold_sec);
			ssleep(1);
		}
	}

	pr_info("eksm-p: one-shot scan finished, worker exiting\n");
	return 0;
}

static int __init eksm_p_init(void)
{
	pr_info("eksm-p: init (PID allowlist)\n");

	worker = kthread_run(eksm_p_worker_fn, NULL, "eksm-p_worker");
	if (IS_ERR(worker)) {
		pr_err("eksm-p: kthread_run failed\n");
		return PTR_ERR(worker);
	}

	return 0;
}

static void __exit eksm_p_exit(void)
{
	if (worker) {
		kthread_stop(worker);
		worker = NULL;
	}
	pr_info("eksm-p: unloaded\n");
}

module_init(eksm_p_init);
module_exit(eksm_p_exit);

