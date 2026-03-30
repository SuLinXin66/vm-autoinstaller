-include build.env
export

VERSION  ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
MODULE   := github.com/SuLinXin66/vm-autoinstaller
LDFLAGS  := -s -w \
  -X '$(MODULE)/internal/buildinfo.AppName=$(APP_NAME)' \
  -X '$(MODULE)/internal/buildinfo.RepoURL=$(REPO_URL)' \
  -X '$(MODULE)/internal/buildinfo.Branch=$(BRANCH)' \
  -X '$(MODULE)/internal/buildinfo.Version=$(VERSION)'

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
		cp "$(DIST)/cli/$${os}_$${arch}/$(APP_NAME)$$ext" "$$staging/_cli/$(APP_NAME)$$ext"; \
		echo "  BUILD  installer $$os/$$arch"; \
		GOOS=$$os GOARCH=$$arch CGO_ENABLED=0 \
			go build -ldflags "$(LDFLAGS)" -o "$(DIST)/installer-$${os}-$${arch}$$ext" ./cmd/installer; \
		rm -rf "$$staging"; \
	done

checksums:
	@cd $(DIST) && sha256sum installer-* > checksums.txt 2>/dev/null || true
	@echo "  SUMS   $(DIST)/checksums.txt"

release: installer checksums
	@echo "  DONE   release artifacts in $(DIST)/"
	@ls -lh $(DIST)/installer-* $(DIST)/checksums.txt 2>/dev/null || true

clean:
	rm -rf $(DIST) cmd/installer/staging

test:
	go test ./internal/...
