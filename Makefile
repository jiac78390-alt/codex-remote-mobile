.PHONY: build build-mac build-ios-simulator check package-mac install-mac

build:
	swift build -c release

build-mac:
	/bin/zsh Scripts/build-mac.sh

build-ios-simulator:
	/bin/zsh Scripts/build-ios-simulator.sh

check:
	/bin/zsh Scripts/ci-check.sh

package-mac:
	/bin/zsh Scripts/package-mac.sh

install-mac:
	/bin/zsh Scripts/install-mac.sh
