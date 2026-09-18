# Docent — build, test, install.
#
#   make            build Docent.app and the docent command into ./build
#   make run        build and open the app
#   make install    install both (override DOCENT_APP_DIR / DOCENT_BIN_DIR)
#   make test       unit and end-to-end tests
#   make selftest   drive the real app's model end to end (needs a GUI session)
#   make smoke      type into a real terminal and check what appears
#   make clean      delete build artefacts

.PHONY: all build run install uninstall test selftest smoke clean screenshot

all: build

build:
	./Scripts/build-app.sh release

run: build
	open build/Docent.app

install:
	./Scripts/install.sh

uninstall:
	rm -rf /Applications/Docent.app "$(HOME)/Applications/Docent.app"
	rm -f /usr/local/bin/docent "$(HOME)/.local/bin/docent"
	@echo "removed Docent"

test:
	swift test

## The app's own end-to-end checks, against a docset built for the occasion.
selftest: build
	./Scripts/selftest.sh

## A real terminal, real keystrokes, real screen: what the model tests cannot see.
smoke: build
	./Scripts/smoke.sh

clean:
	rm -rf .build build

## Re-take the pictures in the README.
screenshot: build
	./Scripts/screenshots.sh
