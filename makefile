#===============================================================================
# PulseVM 3.4 - Production-grade static HTTP server
# Makefile - Fully automated build system
#===============================================================================

# Project identity
PROJECT     := pulsevm
VERSION     := 3.4
AUTHOR      := PulseVM Project
LICENSE     := MIT

# Compiler and tools
NASM        := nasm
LD          := ld
RM          := rm -f
MKDIR       := mkdir -p
INSTALL     := install
STRIP       := strip
GIT         := git

# Directories
SRCDIR      := src
OBJDIR      := obj
BINDIR      := bin
DOCDIR      := doc
TESTDIR     := test
WWWDIR      := www

# Source files
ASM_SRC     := $(SRCDIR)/pulsevm.asm
ASM_OBJ     := $(OBJDIR)/pulsevm.o
BINARY      := $(BINDIR)/$(PROJECT)

# Build flags
NASM_FLAGS  := -f elf64 -g -F dwarf
LDFLAGS     := 
OPT_FLAGS   := -O2

# Detect liburing availability
LIBURING    := $(shell ld -luring 2>/dev/null && echo "-luring" || echo "")
HAS_URING   := $(shell [ -n "$(LIBURING)" ] && echo "yes" || echo "no")

# Conditional: if liburing is available, link it; otherwise build without io_uring
ifeq ($(HAS_URING),yes)
    LDFLAGS += $(LIBURING)
    NASM_FLAGS += -DHAS_IO_URING=1
    URING_STATUS := enabled
else
    NASM_FLAGS += -DHAS_IO_URING=0
    URING_STATUS := disabled (install liburing-dev for io_uring support)
endif

# Installation paths
PREFIX      := /usr/local
BINPREFIX   := $(PREFIX)/bin
MANPREFIX   := $(PREFIX)/share/man
SYSTEMD_DIR := /etc/systemd/system

# Colors for output
RESET       := \033[0m
BOLD        := \033[1m
DIM         := \033[2m
RED         := \033[31m
GREEN       := \033[32m
YELLOW      := \033[33m
BLUE        := \033[34m
MAGENTA     := \033[35m
CYAN        := \033[36m
WHITE       := \033[37m

# Emojis
CHECK       := ✅
CROSS       := ❌
GEAR        := ⚙️
ROCKET      := 🚀
PACKAGE     := 📦
BROOM       := 🧹
SHIELD      := 🛡️

#===============================================================================
# Default target
#===============================================================================
.PHONY: all
all: welcome check-deps dirs build sign success

#===============================================================================
# Welcome message
#===============================================================================
.PHONY: welcome
welcome:
	@printf "$(BOLD)$(CYAN)\n"
	@printf "╔══════════════════════════════════════════════════════════╗\n"
	@printf "║                                                          ║\n"
	@printf "║   $(WHITE)PulseVM $(VERSION)$(CYAN) - High-Performance Static HTTP Server        ║\n"
	@printf "║   $(DIM)Pure x86-64 Assembly • io_uring • Zero-Copy • Multi-Core$(CYAN)    ║\n"
	@printf "║                                                          ║\n"
	@printf "╚══════════════════════════════════════════════════════════╝\n"
	@printf "$(RESET)\n"

#===============================================================================
# Dependency checking
#===============================================================================
.PHONY: check-deps
check-deps:
	@printf "$(BOLD)$(BLUE)[$(GEAR)] Checking build dependencies...$(RESET)\n"
	@# Check NASM
	@if command -v $(NASM) > /dev/null 2>&1; then \
		printf "  $(CHECK) $(GREEN)NASM found:$(RESET) $$($(NASM) --version | head -1)\n"; \
	else \
		printf "  $(CROSS) $(RED)NASM not found!$(RESET) Install with: $(YELLOW)sudo apt install nasm$(RESET)\n"; \
		exit 1; \
	fi
	@# Check LD
	@if command -v $(LD) > /dev/null 2>&1; then \
		printf "  $(CHECK) $(GREEN)GNU LD found:$(RESET) $$($(LD) --version | head -1)\n"; \
	else \
		printf "  $(CROSS) $(RED)GNU LD not found!$(RESET) Install with: $(YELLOW)sudo apt install binutils$(RESET)\n"; \
		exit 1; \
	fi
	@# Check liburing
	@if [ "$(HAS_URING)" = "yes" ]; then \
		printf "  $(CHECK) $(GREEN)liburing found:$(RESET) io_uring support $(GREEN)enabled$(RESET)\n"; \
	else \
		printf "  $(YELLOW)⚠️  liburing not found:$(RESET) io_uring support $(YELLOW)$(URING_STATUS)$(RESET)\n"; \
		printf "    $(DIM)Install with: sudo apt install liburing-dev$(RESET)\n"; \
	fi
	@# Check for recommended tools
	@if command -v strip > /dev/null 2>&1; then \
		printf "  $(CHECK) $(GREEN)strip found$(RESET)\n"; \
	fi
	@if command -v git > /dev/null 2>&1; then \
		printf "  $(CHECK) $(GREEN)git found$(RESET)\n"; \
	fi
	@printf "\n"

#===============================================================================
# Create directories
#===============================================================================
.PHONY: dirs
dirs:
	@$(MKDIR) $(OBJDIR) $(BINDIR)

#===============================================================================
# Main build target
#===============================================================================
.PHONY: build
build: $(BINARY)
	@printf "$(BOLD)$(GREEN)[$(CHECK)] Build completed successfully!$(RESET)\n"

#===============================================================================
# Compile and link
#===============================================================================
$(BINARY): $(ASM_OBJ)
	@printf "$(BOLD)$(BLUE)[$(GEAR)] Linking...$(RESET)\n"
	@$(LD) $(LDFLAGS) -o $@ $^
	@printf "  $(CHECK) $(GREEN)Linked:$(RESET) $(BINARY)\n"
	@# Strip debug symbols for release build
	@if [ -z "$(DEBUG)" ]; then \
		$(STRIP) --strip-all $(BINARY) 2>/dev/null && \
		printf "  $(CHECK) $(GREEN)Stripped debug symbols$(RESET)\n" || true; \
	fi
	@# Show binary size
	@printf "  $(DIM)Binary size: $$(du -h $(BINARY) | cut -f1)$(RESET)\n"

$(ASM_OBJ): $(ASM_SRC)
	@printf "$(BOLD)$(BLUE)[$(GEAR)] Assembling...$(RESET)\n"
	@$(NASM) $(NASM_FLAGS) $(OPT_FLAGS) -o $@ $<
	@printf "  $(CHECK) $(GREEN)Assembled:$(RESET) $(ASM_SRC)\n"

#===============================================================================
# Success message
#===============================================================================
.PHONY: success
success:
	@printf "\n$(BOLD)$(GREEN)╔══════════════════════════════════════════════════════════╗\n"
	@printf "║  $(ROCKET)  Build Complete!                                    ║\n"
	@printf "║                                                          ║\n"
	@printf "║  $(WHITE)Binary:$(RESET) $(BINARY)                         \n"
	@printf "║  $(WHITE)Run:$(RESET)   ./$(BINARY) [port] [root_dir]       \n"
	@printf "║  $(WHITE)Example:$(RESET) ./$(BINARY) 8080 ./www              \n"
	@printf "║                                                          ║\n"
	@printf "╚══════════════════════════════════════════════════════════╝$(RESET)\n\n"

#===============================================================================
# Quick start - build and run with defaults
#===============================================================================
.PHONY: run
run: all
	@printf "$(BOLD)$(CYAN)[$(ROCKET)] Starting PulseVM on port 8080...$(RESET)\n"
	@$(MKDIR) $(WWWDIR) 2>/dev/null || true
	@if [ ! -f $(WWWDIR)/index.html ]; then \
		printf "<html><body><h1>PulseVM $(VERSION) Running!</h1></body></html>" > $(WWWDIR)/index.html; \
	fi
	@./$(BINARY) 8080 $(WWWDIR)

#===============================================================================
# Debug build (with symbols, no strip)
#===============================================================================
.PHONY: debug
debug: DEBUG := 1
debug: NASM_FLAGS += -DDEBUG=1
debug: OPT_FLAGS := -O0
debug: all
	@printf "$(YELLOW)[$(GEAR)] Debug build ready (symbols preserved)$(RESET)\n"

#===============================================================================
# Install to system
#===============================================================================
.PHONY: install
install: all
	@printf "$(BOLD)$(BLUE)[$(PACKAGE)] Installing PulseVM...$(RESET)\n"
	@$(INSTALL) -d $(DESTDIR)$(BINPREFIX)
	@$(INSTALL) -m 755 $(BINARY) $(DESTDIR)$(BINPREFIX)/$(PROJECT)
	@printf "  $(CHECK) $(GREEN)Installed:$(RESET) $(DESTDIR)$(BINPREFIX)/$(PROJECT)\n"
	@# Install systemd service if systemd is available
	@if [ -d $(SYSTEMD_DIR) ]; then \
		printf "$(BOLD)$(BLUE)[$(GEAR)] Installing systemd service...$(RESET)\n"; \
		$(INSTALL) -m 644 $(SRCDIR)/pulsevm.service $(DESTDIR)$(SYSTEMD_DIR)/pulsevm.service 2>/dev/null && \
		printf "  $(CHECK) $(GREEN)Service installed$(RESET)\n" || \
		printf "  $(YELLOW)⚠️  Service file not found, skipping$(RESET)\n"; \
	fi
	@printf "$(BOLD)$(GREEN)[$(CHECK)] Installation complete!$(RESET)\n"

#===============================================================================
# Uninstall
#===============================================================================
.PHONY: uninstall
uninstall:
	@printf "$(BOLD)$(YELLOW)[$(BROOM)] Uninstalling PulseVM...$(RESET)\n"
	@$(RM) $(DESTDIR)$(BINPREFIX)/$(PROJECT)
	@$(RM) $(DESTDIR)$(SYSTEMD_DIR)/pulsevm.service
	@printf "  $(CHECK) $(GREEN)Uninstalled$(RESET)\n"

#===============================================================================
# Testing
#===============================================================================
.PHONY: test
test: all
	@printf "$(BOLD)$(BLUE)[$(GEAR)] Running tests...$(RESET)\n"
	@$(MKDIR) $(WWWDIR)
	@echo "<html><body><h1>Test Page</h1></body></html>" > $(WWWDIR)/test.html
	@# Start server in background
	@./$(BINARY) 8080 $(WWWDIR) &
	@SERVER_PID=$$!; \
	sleep 1; \
	printf "  Testing HTTP 200... "; \
	if curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/test.html | grep -q 200; then \
		printf "$(GREEN)PASS$(RESET)\n"; \
	else \
		printf "$(RED)FAIL$(RESET)\n"; \
	fi; \
	printf "  Testing HTTP 404... "; \
	if curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/nonexistent | grep -q 404; then \
		printf "$(GREEN)PASS$(RESET)\n"; \
	else \
		printf "$(RED)FAIL$(RESET)\n"; \
	fi; \
	kill $$SERVER_PID 2>/dev/null; \
	wait $$SERVER_PID 2>/dev/null
	@printf "\n$(BOLD)$(GREEN)[$(CHECK)] Tests complete!$(RESET)\n"

#===============================================================================
# Benchmark
#===============================================================================
.PHONY: bench
bench: all
	@printf "$(BOLD)$(MAGENTA)[$(ROCKET)] Starting benchmark...$(RESET)\n"
	@printf "$(DIM)Make sure 'wrk' or 'ab' is installed$(RESET)\n\n"
	@$(MKDIR) $(WWWDIR)
	@dd if=/dev/urandom of=$(WWWDIR)/bench.dat bs=1024 count=1024 2>/dev/null
	@./$(BINARY) 8080 $(WWWDIR) &
	@SERVER_PID=$$!; \
	sleep 1; \
	if command -v wrk > /dev/null 2>&1; then \
		printf "$(BOLD)wrk benchmark:$(RESET)\n"; \
		wrk -t4 -c100 -d10s http://localhost:8080/bench.dat; \
	elif command -v ab > /dev/null 2>&1; then \
		printf "$(BOLD)ab benchmark:$(RESET)\n"; \
		ab -n 10000 -c 100 http://localhost:8080/bench.dat; \
	else \
		printf "$(YELLOW)Install 'wrk' or 'apache2-utils' for benchmarks$(RESET)\n"; \
	fi; \
	kill $$SERVER_PID 2>/dev/null; \
	wait $$SERVER_PID 2>/dev/null; \
	$(RM) $(WWWDIR)/bench.dat

#===============================================================================
# Create release tarball
#===============================================================================
.PHONY: release
release: clean all
	@printf "$(BOLD)$(BLUE)[$(PACKAGE)] Creating release tarball...$(RESET)\n"
	@$(MKDIR) release
	@cp $(BINARY) release/
	@cp README.md release/ 2>/dev/null || true
	@cp LICENSE release/ 2>/dev/null || true
	@tar -czf $(PROJECT)-$(VERSION)-x86_64.tar.gz release/
	@$(RM) -r release
	@printf "  $(CHECK) $(GREEN)Created:$(RESET) $(PROJECT)-$(VERSION)-x86_64.tar.gz\n"

#===============================================================================
# Development helpers
#===============================================================================
.PHONY: watch
watch:
	@printf "$(BOLD)$(CYAN)Watching for changes... (Ctrl+C to stop)$(RESET)\n"
	@while true; do \
		$(MAKE) -s build 2>/dev/null; \
		inotifywait -q -e modify $(ASM_SRC) 2>/dev/null || sleep 2; \
	done

.PHONY: format
format:
	@printf "$(BOLD)$(BLUE)[$(BROOM)] Formatting assembly source...$(RESET)\n"
	@if command -v asmfmt > /dev/null 2>&1; then \
		asmfmt -w $(ASM_SRC) && printf "  $(CHECK) Formatted\n"; \
	else \
		printf "  $(YELLOW)⚠️  asmfmt not installed, skipping$(RESET)\n"; \
	fi

.PHONY: lint
lint:
	@printf "$(BOLD)$(BLUE)[$(SHIELD)] Linting...$(RESET)\n"
	@$(NASM) $(NASM_FLAGS) -E -o /dev/null $(ASM_SRC) 2>&1 | grep -i "warning\|error" || \
		printf "  $(CHECK) $(GREEN)No warnings or errors$(RESET)\n"

#===============================================================================
# Docker support
#===============================================================================
.PHONY: docker-build
docker-build:
	@printf "$(BOLD)$(BLUE)[$(PACKAGE)] Building Docker image...$(RESET)\n"
	@docker build -t $(PROJECT):$(VERSION) .

.PHONY: docker-run
docker-run:
	@printf "$(BOLD)$(CYAN)[$(ROCKET)] Starting Docker container...$(RESET)\n"
	@docker run -p 8080:8080 -v $(PWD)/www:/var/www/html $(PROJECT):$(VERSION)

#===============================================================================
# Help
#===============================================================================
.PHONY: help
help:
	@printf "$(BOLD)$(CYAN)\n"
	@printf "PulseVM $(VERSION) - Build System\n"
	@printf "$(RESET)\n"
	@printf "$(BOLD)Usage:$(RESET) make [target]\n"
	@printf "\n"
	@printf "$(BOLD)Build Targets:$(RESET)\n"
	@printf "  $(GREEN)all$(RESET)        - Build PulseVM (default)\n"
	@printf "  $(GREEN)debug$(RESET)      - Build with debug symbols\n"
	@printf "  $(GREEN)release$(RESET)    - Create release tarball\n"
	@printf "\n"
	@printf "$(BOLD)Run Targets:$(RESET)\n"
	@printf "  $(GREEN)run$(RESET)        - Build and start server on port 8080\n"
	@printf "  $(GREEN)test$(RESET)       - Build and run tests\n"
	@printf "  $(GREEN)bench$(RESET)      - Build and run benchmarks\n"
	@printf "\n"
	@printf "$(BOLD)Install Targets:$(RESET)\n"
	@printf "  $(GREEN)install$(RESET)    - Install to $(PREFIX)\n"
	@printf "  $(GREEN)uninstall$(RESET)  - Remove from $(PREFIX)\n"
	@printf "\n"
	@printf "$(BOLD)Dev Targets:$(RESET)\n"
	@printf "  $(GREEN)watch$(RESET)      - Auto-rebuild on changes\n"
	@printf "  $(GREEN)format$(RESET)     - Format assembly source\n"
	@printf "  $(GREEN)lint$(RESET)       - Check for warnings\n"
	@printf "\n"
	@printf "$(BOLD)Docker Targets:$(RESET)\n"
	@printf "  $(GREEN)docker-build$(RESET) - Build Docker image\n"
	@printf "  $(GREEN)docker-run$(RESET)   - Run in Docker container\n"
	@printf "\n"
	@printf "$(BOLD)Cleanup:$(RESET)\n"
	@printf "  $(GREEN)clean$(RESET)      - Remove build artifacts\n"
	@printf "  $(GREEN)distclean$(RESET)  - Remove everything built\n"
	@printf "\n"
	@printf "$(BOLD)Examples:$(RESET)\n"
	@printf "  make                      # Build the server\n"
	@printf "  make run                  # Build and run on port 8080\n"
	@printf "  make DEBUG=1              # Build with debug info\n"
	@printf "  make install PREFIX=/usr  # Install system-wide\n"
	@printf "\n"

#===============================================================================
# Cleanup
#===============================================================================
.PHONY: clean
clean:
	@printf "$(BOLD)$(YELLOW)[$(BROOM)] Cleaning build artifacts...$(RESET)\n"
	@$(RM) -r $(OBJDIR) $(BINDIR)
	@printf "  $(CHECK) $(GREEN)Cleaned$(RESET)\n"

.PHONY: distclean
distclean: clean
	@printf "$(BOLD)$(YELLOW)[$(BROOM)] Deep cleaning...$(RESET)\n"
	@$(RM) -r release
	@$(RM) $(PROJECT)-*.tar.gz
	@printf "  $(CHECK) $(GREEN)All clean$(RESET)\n"

#===============================================================================
# Verify NASM version compatibility
#===============================================================================
.PHONY: check-nasm
check-nasm:
	@NASM_VER=$$($(NASM) --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1); \
	if [ -n "$$NASM_VER" ]; then \
		printf "  $(CHECK) NASM version: $$NASM_VER\n"; \
	else \
		printf "  $(CROSS) Cannot detect NASM version\n"; \
	fi

#===============================================================================
# Print build configuration
#===============================================================================
.PHONY: config
config:
	@printf "$(BOLD)$(CYAN)Build Configuration:$(RESET)\n"
	@printf "  $(DIM)Project:$(RESET)    $(PROJECT) v$(VERSION)\n"
	@printf "  $(DIM)NASM:$(RESET)       $(NASM)\n"
	@printf "  $(DIM)NASM Flags:$(RESET) $(NASM_FLAGS)\n"
	@printf "  $(DIM)LD Flags:$(RESET)   $(LDFLAGS)\n"
	@printf "  $(DIM)io_uring:$(RESET)   $(URING_STATUS)\n"
	@printf "  $(DIM)Debug:$(RESET)      $(if $(DEBUG),yes,no)\n"
	@printf "  $(DIM)Prefix:$(RESET)     $(PREFIX)\n"
	@printf "  $(DIM)Binary:$(RESET)     $(BINARY)\n"

#===============================================================================
# Make all targets phony (no filesystem artifacts)
#===============================================================================
.PHONY: all welcome check-deps dirs build success run debug install uninstall
.PHONY: test bench release watch format lint docker-build docker-run
.PHONY: help clean distclean check-nasm config