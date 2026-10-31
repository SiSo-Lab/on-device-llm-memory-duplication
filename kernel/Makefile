# Kleaf passes KERNEL_SRC, O and M. For a manual build:
#   make KERNEL_SRC=<kernel source> O=<kernel build dir>
KSRC ?= $(KERNEL_SRC)
KSRC ?= $(ROOT_DIR)/$(KERNEL_DIR)
KSRC ?= $(ROOT_DIR)/common
KSRC ?= $(CURDIR)/../common

KOUT ?= $(O)

MOD ?= $(M)
ifeq ($(strip $(MOD)),)
MOD := $(CURDIR)
endif

.PHONY: all modules modules_install clean

all: modules

modules:
	$(MAKE) -C $(KSRC) O=$(KOUT) M=$(MOD) modules

modules_install:
	$(MAKE) -C $(KSRC) O=$(KOUT) M=$(MOD) \
		INSTALL_MOD_PATH="$(INSTALL_MOD_PATH)" \
		INSTALL_MOD_DIR="$(INSTALL_MOD_DIR)" \
		INSTALL_MOD_STRIP="$(INSTALL_MOD_STRIP)" \
		DEPMOD="$(DEPMOD)" \
		modules_install

clean:
	$(MAKE) -C $(KSRC) O=$(KOUT) M=$(MOD) clean
