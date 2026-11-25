.PHONY: all package review test
all: package

package:
	@.github/scripts/package-rootless.sh

review:
	@Independent/scripts/package.sh review

test:
	@swift test --package-path Independent -c release
