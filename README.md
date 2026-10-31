# Measuring In-Memory Weight Duplication Across On-Device LLM Apps in Mobile Environments

Reproduction materials for the IEEE Embedded Systems Letters paper by Joonhee Seong and Jiwoong Park, Sungshin Women's University.

Two apps are measured: P1, the llama.cpp Android example, and P2, PolyEngineInfer. Each loading condition uses its
own build of both apps:

| Condition | Used in | Model loading | P1 package | P2 package |
|---|---|---|---|---|
| per-app-copy | Fig. 1 | `mmap` of each app's own copy | `com.example.llama.aichat.a` | `dev.filipfan.polyengineinfer.a` |
| same-inode | Fig. 1 | `mmap` of one shared file | `com.example.llama.hard` | `dev.filipfan.polyengineinfer.hard` |
| probe | Figs. 1-2 | `O_DIRECT` read into anonymous memory | `com.example.llama.aichat` | `dev.filipfan.polyengineinfer.mmapasdio` |
| lora | Fig. 3 | probe, plus LoRA adapter loading | `com.example.llama.aichat` | `dev.filipfan.polyengineinfer.mmapasdio` |

The kernel module `kernel/eksm_p.c` marks the memory of the two measured processes as mergeable; KSM itself is
unmodified.

## Layout

```
apps/       modified app sources per condition; fetch.sh (upstream checkout + modified files), build.sh
kernel/     eksm_p module, guest kernel build changes and pinned Kleaf manifest, build script
models/     model download, Fig. 3 model build (LoRA merge, GGUF conversion), hash check
scripts/    Cuttlefish setup and boot, one measurement run (measure.sh), summary over runs
manifests/  SHA-256 of the models used for the paper
```

## Requirements

- x86-64 host running Ubuntu 24.04 with KVM and at least 16 GB of memory (the device has 12 GiB).
- Measured host: Ubuntu 24.04.3 LTS, Linux 6.14.9 (custom build, THP `madvise`), 2 × Intel Xeon Silver 4514Y,
  251.6 GiB of memory.
- Disk: about 50 GB for apps, models and images; about 140 GB free where the device runs (`launch_cvd` allocates the
  128 GiB userdata image; `DATA_IMG_SIZE=32G` needs about 45 GB); about 100 GB for the kernel build.
- Cuttlefish host packages `cuttlefish-base` and `cuttlefish-user` 1.57.0, installed with `apt` from the Android
  Artifact Registry repository (https://github.com/google/android-cuttlefish); the user must be in the `kvm`,
  `cvdnetwork` and `render` groups.
- Cuttlefish build 14654133, target `aosp_cf_x86_64_only_phone`: `aosp_cf_x86_64_only_phone-img-14654133.zip` and
  `cvd-host_package.tar.gz`, each downloaded from
  `https://ci.android.com/builds/submitted/14654133/aosp_cf_x86_64_only_phone-userdebug/latest/raw/<file>`.
- JDK 17 (the same-inode apps do not build with a newer JDK) and an Android SDK with platform 36, build-tools 35.0.0,
  NDK 29.0.13113456 and NDK 28.2.13676358, and SDK CMake 3.31.6 (P1) and 3.22.1 (P2).
- `repo`, `git`, `cmake`, `g++`, `unzip`, Python 3.12 with `venv` (`numpy==1.26.4` has no wheel for 3.13).
- A Hugging Face token with access to `meta-llama/Llama-3.2-1B-Instruct` (Fig. 3 only).

All commands below are run from the repository root. Inputs for the measurements are collected in one directory, and
the Python steps use one virtual environment:

```bash
export ASSETS=$PWD/assets
python3 -m venv build/venv
build/venv/bin/pip install -r models/requirements-lora.txt --extra-index-url https://download.pytorch.org/whl/cpu
```

## 1. Build the apps

Accept the SDK licenses and install the SDK components:

```bash
sdkmanager=/path/to/android-sdk/cmdline-tools/latest/bin/sdkmanager
yes | $sdkmanager --licenses
$sdkmanager "platforms;android-36" "build-tools;35.0.0" "ndk;29.0.13113456" "ndk;28.2.13676358" \
  "cmake;3.31.6" "cmake;3.22.1"
```

```bash
for c in per-app-copy same-inode probe lora; do
  bash apps/fetch.sh $c build/src/$c
  JAVA_HOME=/path/to/jdk-17 ANDROID_HOME=/path/to/android-sdk bash apps/build.sh $c build/src/$c $ASSETS/apks/$c
done
```

`fetch.sh` checks out llama.cpp and PolyEngineInfer at the commits pinned in `apps/fetch.sh` and copies
`apps/<condition>/` over them. `build.sh` writes `p1.apk` and `p2.apk`.

## 2. Build the guest kernel and the module

```bash
bash kernel/build_kernel.sh build/kernel
```

This syncs the Kleaf workspace pinned in `kernel/kleaf-manifest.xml` (android-mainline `08628d68ed23`), applies
`kernel/android-mainline-build.diff` and `kernel/virtual-device-build.diff` (KSM enabled, `eksm_p` packaged) and builds
`virtual_device_x86_64_dist`. Output: `build/kernel/out/virtual_device_x86_64/dist/{bzImage,initramfs.img,eksm_p.ko}`.

## 3. Prepare the models

Figs. 1-2 (seven Q4_K_M GGUF files):

```bash
build/venv/bin/python models/download_models.py $ASSETS/models gguf
```

Fig. 3 (base model, five merged models and four adapters), built with an unmodified llama.cpp at `8bc492e`:

```bash
git clone https://github.com/ggml-org/llama.cpp build/llama.cpp && git -C build/llama.cpp checkout 8bc492e
HF_TOKEN=<token> build/venv/bin/python models/download_models.py build/dl base
build/venv/bin/python models/download_models.py build/dl adapters
PYTHON=build/venv/bin/python bash models/build_lora_models.sh build/llama.cpp \
  build/dl/hf/Llama-3.2-1B-Instruct build/dl/adapters $ASSETS/lora
```

Check all files against `manifests/models.csv`:

```bash
build/venv/bin/python models/check_models.py $ASSETS/models $ASSETS/lora
```

All files must be `OK`. The run scripts also check the SHA-256 of every model file and stop on a mismatch.

## 4. Prepare the device

```bash
bash scripts/setup_cuttlefish.sh aosp_cf_x86_64_only_phone-img-14654133.zip cvd-host_package.tar.gz \
  build/kernel/out/virtual_device_x86_64/dist cvd-home cvd-images
```

`setup_cuttlefish.sh` checks the SHA-256 of the two downloads against the values in the script, unpacks the host package into
`cvd-home` and the images into `cvd-images`, and copies `bzImage`, `initramfs.img` and `eksm_p.ko` into `cvd-home`.

crosvm needs unprivileged user namespaces; run once after each host boot:

```bash
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
```

`measure.sh` creates a fresh VM for every run from `GOOD_HOME` and `SYSTEM_IMAGE_DIR`: it stops any running instance,
deletes the instance directories and the userdata image under `FRESH`, boots the device with
`scripts/boot_cuttlefish.sh`, and stops it with `stop_cvd` at the end of the run. The boot output is saved as
`<run_dir>/host/boot.log`. In the terminal for the measurements:

```bash
export ASSETS=$PWD/assets SERIAL=0.0.0.0:6520 ADB_BIN=$PWD/cvd-home/bin/adb KO=$PWD/cvd-home/eksm_p.ko \
  GOOD_HOME=$PWD/cvd-home SYSTEM_IMAGE_DIR=$PWD/cvd-images FRESH=$PWD/build/cf-run
```

To start a device by hand outside a run, run `bash scripts/boot_cuttlefish.sh` with these variables in its own
terminal (it stays in the foreground) and stop it with:

```bash
HOME=$PWD/cvd-home cvd-home/bin/stop_cvd
```

## 5. Run the experiments

One run:

```bash
bash scripts/measure.sh <condition> <pair> <run> <run_dir>
```

It boots a new VM, runs `run_per_app_copy.sh`, `run_same_inode.sh`, `run_probe.sh` or `run_lora.sh` for the condition, then writes
`values.csv` with `extract_values.py`. The run script installs the APKs, stages the models and checks their SHA-256
on the device, reboots the guest, loads the model in both apps, sends up to 15 prompts to each app, records
`/proc/<pid>/smaps` of both apps, loads `eksm_p` for the two processes, waits until the KSM counters are stable,
records the memory again and pulls everything into `<run_dir>`. The run succeeded if `<run_dir>/STATUS` is
`PULLED_OK`; the values are in `<run_dir>/values.csv`. For per-app-copy, probe and same-inode, `measure.sh` exits 1 if
the warm-up check finds that an app did not run inference before KSM (`<run_dir>/warmup_check.json`); for
per-app-copy and probe, the number of prompts P1 accepted is recorded there as `per_app.p1.prompts`. Each run needs a
new `<run_dir>`. One run takes about 50 minutes.

Fig. 1 (byte-identical Llama-3.2-1B pair):

```bash
for r in 1 2 3 4 5; do
  bash scripts/measure.sh per-app-copy 1B/1B $r runs/fig1/per-app-copy_r$r
  bash scripts/measure.sh probe 1B/1B $r runs/fig1/probe_r$r
  bash scripts/measure.sh same-inode 1B/1B $r runs/fig1/same-inode_r$r
done
```

Fig. 2 (eight model pairs, probe; the 1B/1B pair is the Fig. 1 probe run):

```bash
for p in 3B/3B Q1.5/Q1.5 1B/3B 3B/3B-kor Q1.5/S1.7 3B/Q3B 1B/G2B; do
  for r in 1 2 3 4 5; do bash scripts/measure.sh probe $p $r runs/fig2/${p/\//_}_r$r; done
done
```

| Pair | P1 | P2 |
|---|---|---|
| 1B/1B, 3B/3B, Q1.5/Q1.5 | same file in both apps | |
| 1B/3B | Llama-3.2-1B-Instruct | Llama-3.2-3B-Instruct |
| 3B/3B-kor | Llama-3.2-3B-Instruct | Llama-3.2-Korean-Bllossom-3B |
| Q1.5/S1.7 | Qwen2.5-1.5B-Instruct | SmolLM2-1.7B-Instruct |
| 3B/Q3B | Llama-3.2-3B-Instruct | Qwen2.5-3B-Instruct |
| 1B/G2B | Llama-3.2-1B-Instruct | gemma-2-2b-it |

Fig. 3 (LoRA adapters A/B, C/D and A/C on Llama-3.2-1B-Instruct):

```bash
for m in lora-merged lora-separated; do
  for p in A/B C/D A/C; do
    for r in 1 2 3 4 5; do bash scripts/measure.sh $m $p $r runs/fig3/${m}_${p/\//_}_r$r; done
  done
done
```

`lora-merged`: each app loads its own model with the adapter merged into the weights. `lora-separated`: both apps
load the base model and apply their adapter at load time.

### Measurement settings

| Setting | Value | Where |
|---|---|---|
| Guest memory | 12288 MB | `scripts/boot_cuttlefish.sh` |
| Guest kernel | x86-64, 4 KiB pages; no swap or zram | `kernel/guest-kernel.config` |
| KSM | `pages_to_scan` 20000, `sleep_millisecs` 20, `use_zero_pages` 0; other knobs kernel defaults | `scripts/probe/ksm_backend.sh` |
| Module load | `insmod eksm_p.ko target_pids=<pid>,<pid> verbose=1 hold_sec=0 max_tasks=0 only_private_anon=0 skip_file_vma=0` | `scripts/probe/ksm_backend.sh` |
| Stop rule | counters sampled every 1 s; stable when the first four digits of `pages_shared` and `pages_sharing` are unchanged over three consecutive samples, not before 60 s; at most 300 s | `scripts/probe/ksm_backend.sh` |
| Prompts | 15 per app, P1 then P2 | `scripts/probe/runner.sh` |
| SELinux | permissive in same-inode only | `scripts/run_same_inode.sh` |
| Page cache, KSM state | fresh VM per run; reboot after staging | `scripts/lib.sh` |

The device is stopped at the end of each run; its final state is in the run directory:

```bash
cat <run_dir>/device/ksm_sysfs_final.txt
grep 'target_pids=' <run_dir>/host/runner_stdout.log
grep 'eksm-p: PASS_DONE' <run_dir>/device/dmesg.txt
```

A run requires `tasks_applied(at_least_1_vma)=2` in the `PASS_DONE` line.

## 6. Results

```bash
python3 scripts/summarize.py runs/fig1 runs/fig2 runs/fig3
```

prints the mean and the 95% confidence interval (Student-t) per condition and pair. Values reported in the paper:

| Figure | Column | Expected |
|---|---|---|
| Fig. 1 | `pss_before_MiB` | about 2,580 MiB (probe), 1,820 MiB (same-inode) |
| Fig. 1 | `recovery_MiB` (`recovery_%`) | probe 844 MiB (32.7%); same-inode 80-100 MiB (4.5-5.5%); per-app-copy 83 MiB (3.2%) |
| Fig. 2 | `shared_MiB` | 1B/1B 773, 3B/3B 1,932, Q1.5/Q1.5 946; 1B/3B 11, 3B/3B-kor 13, Q1.5/S1.7 9, 3B/Q3B 10, 1B/G2B 9 |
| Fig. 3 | `pct_of_base` | merged A/B 93.2, C/D 28.3, A/C 28.2; separated about 99.3 for all pairs |

## License

Scripts, manifests and the model build tools are under the MIT License (see `LICENSE`). `kernel/eksm_p.c` is GPL-2.0.
The files under `apps/` are modifications of llama.cpp (MIT) and PolyEngineInfer (Apache-2.0; its NOTICE is in
`apps/PolyEngineInfer-NOTICE`) and keep their upstream licenses.
