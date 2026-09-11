# stratify — build, check, install.
#
# The binary is built from source rather than committed. A committed Mach-O would be
# wrong on every machine but this one, and the build is a two-second `lake build` with
# no dependencies beyond the Lean toolchain pinned in lean/lean-toolchain.

LEAN   := lean
BIN    := $(LEAN)/.lake/build/bin/stratify
PREFIX ?= $(HOME)/.local

.PHONY: all build check install uninstall clean

all: build

build:
	cd $(LEAN) && lake build

# The deterministic half of the eval suite. See evals/README.md.
check: build
	./evals/run-checks.sh --no-build

# Copies rather than symlinks: a symlink into .lake/build would break on `lake clean`,
# and a stratify that vanishes mid-run would take the user's status line with it.
install: build
	install -d $(PREFIX)/bin
	install -m 0755 $(BIN) $(PREFIX)/bin/stratify
	@echo
	@echo "installed $(PREFIX)/bin/stratify"
	@echo
	@echo "The sensor is a separate, opt-in step — window usage and reset times are not"
	@echo "on disk anywhere, so without it stratify can count sessions and tokens but"
	@echo "cannot see the window at all. To see the change it needs:"
	@echo
	@echo "    stratify install-sensor"
	@echo
	@echo "That prints the settings block and modifies nothing. Applying it edits"
	@echo "~/.claude/settings.json, which affects every Claude session on this machine."

uninstall:
	rm -f $(PREFIX)/bin/stratify

clean:
	cd $(LEAN) && lake clean
