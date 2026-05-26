KERNELDIR ?= /lib/modules/$(shell uname -r)/build
SRC       := $(shell pwd)/src
PATCHDIR  := $(shell pwd)/patches
STAMP     := $(SRC)/.patches-applied

all: patch
	$(MAKE) -C $(KERNELDIR) M=$(SRC) modules

# Apply every patch in patches/*.patch (sorted) once. The stamp file
# prevents re-application on incremental builds.
patch: $(STAMP)
$(STAMP):
	@if [ -d "$(PATCHDIR)" ] && ls "$(PATCHDIR)"/*.patch >/dev/null 2>&1; then \
	    for p in $$(ls "$(PATCHDIR)"/*.patch | sort); do \
	        echo "Applying $$(basename $$p)"; \
	        (cd "$(SRC)" && patch -p1 --silent < "$$p") || exit 1; \
	    done; \
	fi
	@touch "$(STAMP)"

clean:
	$(MAKE) -C $(KERNELDIR) M=$(SRC) clean
	@if [ -f "$(STAMP)" ]; then \
	    for p in $$(ls "$(PATCHDIR)"/*.patch | sort -r); do \
	        echo "Reverting $$(basename $$p)"; \
	        (cd "$(SRC)" && patch -p1 -R --silent < "$$p") || true; \
	    done; \
	    rm -f "$(STAMP)"; \
	fi

modules_install:
	$(MAKE) -C $(KERNELDIR) M=$(SRC) modules_install

.PHONY: all patch clean modules_install
