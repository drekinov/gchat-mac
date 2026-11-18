XCODEBUILD = xcodebuild -project App/gchat-mac.xcodeproj -scheme gchat-mac -configuration Debug \
	-derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages
APP = build/DerivedData/Build/Products/Debug/gchat-mac.app
BIN = $(APP)/Contents/MacOS/gchat-mac
XCODEBUILD_RELEASE = xcodebuild -project App/gchat-mac.xcodeproj -scheme gchat-mac -configuration Release \
	-derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages
RELEASE_BIN = build/DerivedData/Build/Products/Release/gchat-mac.app/Contents/MacOS/gchat-mac
BENCH_SECONDS ?= 240
BENCH_FLAGS = $(if $(ACCOUNTS),--bench-accounts $(ACCOUNTS)) $(if $(TRAFFIC),--bench-traffic)
FORMAT_PATHS = Sources Tests App/Sources Package.swift

.PHONY: icon signing gen build build-release test run fake footprint keychain-probe keychain-acl-check snapshots bench bench-debug format lint clean

ICONSET = App/Sources/Assets.xcassets/AppIcon.appiconset

icon:
	swift scripts/make_icon.swift build/icon-1024.png
	for s in 16 32 64 128 256 512 1024; do sips -z $$s $$s build/icon-1024.png --out $(ICONSET)/icon_$$s.png >/dev/null; done

signing:
	@id=$$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed -E 's/^[^"]*"([^"]*)".*/\1/'); \
	team=""; \
	if [ -n "$$id" ]; then \
		team=$$(security find-certificate -c "$$id" -p | openssl x509 -noout -subject -nameopt RFC2253 \
			| tr ',' '\n' | sed -n 's/^OU=//p' | head -1); \
	fi; \
	if [ -n "$$id" ] && [ -n "$$team" ]; then \
		printf 'DEVELOPMENT_TEAM = %s\n' "$$team" > App/Local.xcconfig; \
		echo "signing: using '$$id' (team $$team)"; \
	else \
		printf 'CODE_SIGN_IDENTITY = -\nDEVELOPMENT_TEAM =\n' > App/Local.xcconfig; \
		echo "signing: no usable Apple Development identity found; ad-hoc signing"; \
	fi

gen: signing
	xcodegen generate --spec App/project.yml

build: gen
	$(XCODEBUILD) build

test:
	swift test

run:
	open $(APP)

fake:
	open $(APP) --args --fake $(if $(ACCOUNTS),--fake-accounts $(ACCOUNTS))

footprint:
	@footprint -p gchat-mac || echo "footprint: gchat-mac is not running"
	@vmmap --summary gchat-mac | tail -40 || echo "vmmap: gchat-mac is not running"

keychain-probe: build
	$(BIN) --keychain-probe write
	$(XCODEBUILD) CURRENT_PROJECT_VERSION=2 build
	$(BIN) --keychain-probe verify
	security add-generic-password -U -s io.github.drekinov.gchat-mac.probe.foreign -a probe -w probe-secret
	$(BIN) --keychain-probe foreign
	-security delete-generic-password -s io.github.drekinov.gchat-mac.probe.foreign -a probe
	$(BIN) --keychain-probe loopback
	@echo "keychain-probe: all checks passed"

snapshots: build
	set -o pipefail; $(BIN) --snapshot build/snapshots | python3 -I scripts/decode_snapshots.py build/snapshots

build-release: gen
	$(XCODEBUILD_RELEASE) build

bench: build-release
	scripts/bench.sh build/DerivedData/Build/Products/Release/gchat-mac.app $(BENCH_SECONDS) $(BENCH_FLAGS)

bench-debug: build
	scripts/bench.sh $(APP) $(BENCH_SECONDS) $(BENCH_FLAGS)

keychain-acl-check: build
	$(BIN) --keychain-probe write
	@echo "A keychain dialog should now ask whether 'security' may access io.github.drekinov.gchat-mac.probe. Click Deny."
	-security find-generic-password -s io.github.drekinov.gchat-mac.probe -a probe -w
	$(BIN) --keychain-probe verify

format:
	swift format format --in-place --recursive $(FORMAT_PATHS)

lint:
	swift format lint --strict --recursive $(FORMAT_PATHS)

clean:
	rm -rf build App/gchat-mac.xcodeproj
