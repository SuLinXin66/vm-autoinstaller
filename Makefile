-include build.env
export

VERSION  ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
MODULE   := github.com/SuLinXin66/vm-autoinstaller
LDFLAGS  := -s -w \
  -X '$(MODULE)/internal/buildinfo.AppName=$(APP_NAME)' \
  -X '$(MODULE)/internal/buildinfo.RepoURL=$(REPO_URL)' \
  -X '$(MODULE)/internal/buildinfo.Branch=$(BRANCH)' \
  -X '$(MODULE)/internal/buildinfo.Version=$(VERSION)' \
  -X '$(MODULE)/internal/buildinfo.DefaultVMName=$(DEFAULT_VM_NAME)' \
  -X '$(MODULE)/internal/buildinfo.DefaultVMCPUs=$(DEFAULT_VM_CPUS)' \
  -X '$(MODULE)/internal/buildinfo.DefaultVMMemory=$(DEFAULT_VM_MEMORY)' \
  -X '$(MODULE)/internal/buildinfo.DefaultVMDiskSize=$(DEFAULT_VM_DISK_SIZE)' \
  -X '$(MODULE)/internal/buildinfo.DefaultVMUser=$(DEFAULT_VM_USER)' \
  -X '$(MODULE)/internal/buildinfo.DefaultUbuntuVersion=$(DEFAULT_UBUNTU_VERSION)' \
  -X '$(MODULE)/internal/buildinfo.DefaultNetworkMode=$(DEFAULT_NETWORK_MODE)' \
  -X '$(MODULE)/internal/buildinfo.DefaultBridgeName=$(DEFAULT_BRIDGE_NAME)' \
  -X '$(MODULE)/internal/buildinfo.DefaultUbuntuImageBaseURL=$(DEFAULT_UBUNTU_IMAGE_BASE_URL)' \
  -X '$(MODULE)/internal/buildinfo.DefaultAutoYes=$(DEFAULT_AUTO_YES)' \
  -X '$(MODULE)/internal/buildinfo.DefaultEnforceResourceLimit=$(DEFAULT_ENFORCE_RESOURCE_LIMIT)' \
  -X '$(MODULE)/internal/buildinfo.DefaultBuiltinShares=$(DEFAULT_BUILTIN_SHARES)' \
  -X '$(MODULE)/internal/buildinfo.DefaultAPTMirror=$(DEFAULT_APT_MIRROR)' \
  -X '$(MODULE)/internal/buildinfo.DefaultCNMode=$(DEFAULT_CN_MODE)' \
  -X '$(MODULE)/internal/buildinfo.DefaultGitHubProxy=$(DEFAULT_GITHUB_PROXY)'

PLATFORMS := linux/amd64 linux/arm64 windows/amd64 darwin/amd64 darwin/arm64
DIST      := dist

.PHONY: all cli installer release clean tidy

all: release

tidy:
	go mod tidy

cli: tidy
	@for platform in $(PLATFORMS); do \
		os=$${platform%%/*}; arch=$${platform##*/}; \
		ext=""; [ "$$os" = "windows" ] && ext=".exe"; \
		outdir="$(DIST)/cli/$${os}_$${arch}"; \
		mkdir -p "$$outdir"; \
		echo "  BUILD  cli $$os/$$arch"; \
		GOOS=$$os GOARCH=$$arch CGO_ENABLED=0 \
			go build -ldflags "$(LDFLAGS)" -o "$$outdir/$(APP_NAME)$$ext" ./cmd/cli; \
	done

installer: cli
	@for platform in $(PLATFORMS); do \
		os=$${platform%%/*}; arch=$${platform##*/}; \
		ext=""; [ "$$os" = "windows" ] && ext=".exe"; \
		staging="cmd/installer/staging"; \
		rm -rf "$$staging"; \
		mkdir -p "$$staging/linux" "$$staging/windows" "$$staging/vm" "$$staging/_cli"; \
		cp -r scripts/linux/* "$$staging/linux/" 2>/dev/null || true; \
		cp -r scripts/windows/* "$$staging/windows/" 2>/dev/null || true; \
		cp -r scripts/vm/* "$$staging/vm/" 2>/dev/null || true; \
		rm -f "$$staging/vm/config.env"; \
		sed -i \
			-e 's|^VM_NAME=.*|VM_NAME="$(DEFAULT_VM_NAME)"|' \
			-e 's|^VM_CPUS=.*|VM_CPUS=$(DEFAULT_VM_CPUS)|' \
			-e 's|^VM_MEMORY=.*|VM_MEMORY=$(DEFAULT_VM_MEMORY)|' \
			-e 's|^VM_DISK_SIZE=.*|VM_DISK_SIZE=$(DEFAULT_VM_DISK_SIZE)|' \
			-e 's|^VM_USER=.*|VM_USER="$(DEFAULT_VM_USER)"|' \
			-e 's|^UBUNTU_VERSION=.*|UBUNTU_VERSION="$(DEFAULT_UBUNTU_VERSION)"|' \
			-e 's|^NETWORK_MODE=.*|NETWORK_MODE="$(DEFAULT_NETWORK_MODE)"|' \
			-e 's|^BRIDGE_NAME=.*|BRIDGE_NAME="$(DEFAULT_BRIDGE_NAME)"|' \
			-e 's|^DATA_DIR=.*|DATA_DIR="$$HOME/.$(APP_NAME)"|' \
			-e 's|^UBUNTU_IMAGE_BASE_URL=.*|UBUNTU_IMAGE_BASE_URL="$(DEFAULT_UBUNTU_IMAGE_BASE_URL)"|' \
			-e 's|^AUTO_YES=.*|AUTO_YES=$(DEFAULT_AUTO_YES)|' \
			-e 's|^APT_MIRROR=.*|APT_MIRROR=$(DEFAULT_APT_MIRROR)|' \
			-e 's|^CN_MODE=.*|CN_MODE=$(DEFAULT_CN_MODE)|' \
			-e 's|^GITHUB_PROXY=.*|GITHUB_PROXY=$(DEFAULT_GITHUB_PROXY)|' \
			"$$staging/vm/config.env.example"; \
		cp "$(DIST)/cli/$${os}_$${arch}/$(APP_NAME)$$ext" "$$staging/_cli/$(APP_NAME)$$ext"; \
		echo "  BUILD  installer $$os/$$arch"; \
		GOOS=$$os GOARCH=$$arch CGO_ENABLED=0 \
			go build -ldflags "$(LDFLAGS)" -o "$(DIST)/$(APP_NAME)Installer-$${os}-$${arch}$$ext" ./cmd/installer; \
		rm -rf "$$staging"; \
	done

checksums:
	@cd $(DIST) && sha256sum $(APP_NAME)Installer-* > checksums.txt 2>/dev/null || true
	@echo "  SUMS   $(DIST)/checksums.txt"

release: installer checksums
	@echo "  DONE   release artifacts in $(DIST)/"
	@ls -lh $(DIST)/$(APP_NAME)Installer-* $(DIST)/checksums.txt 2>/dev/null || true

clean:
	rm -rf $(DIST) cmd/installer/staging

test:
	go test ./internal/...
