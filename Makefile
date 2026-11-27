.PHONY: dev

LOCAL_DIR ?= ..
LEGACY ?=

dev:
	./run-test.sh --local "$(LOCAL_DIR)"$(if $(LEGACY), --legacy)
