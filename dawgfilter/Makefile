obj-m += dawgfilter.o

# KDIR is overridable so CI can build against a container's installed headers:
# inside a container `uname -r` is the host runner's kernel, which has no
# /lib/modules/<ver>/build. On a real target the default is exactly right.
KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
