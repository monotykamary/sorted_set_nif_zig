ZIG ?= zig
NIF_NAME := sorted_set_nif
NATIVE_DIR := native/$(NIF_NAME)
SRC := $(NATIVE_DIR)/src/lib.zig
PRIV_DIR := priv
OUT := $(PRIV_DIR)/$(NIF_NAME).so
MIX_PRIV_DIR := $(MIX_APP_PATH)/priv

ERL_ROOT := $(shell erl -noshell -eval 'io:format("~s", [code:root_dir()]).' -s init stop)
ERL_VERSION := $(shell erl -noshell -eval 'io:format("~s", [erlang:system_info(version)]).' -s init stop)
ERL_INCLUDE_DIR := $(ERL_ROOT)/erts-$(ERL_VERSION)/include

ifeq ($(OPTIMIZE_NIF),true)
	ZIG_OPT := -OReleaseFast
else
	ZIG_OPT := -ODebug
endif

all: $(OUT) copy_to_mix_priv

$(OUT): $(SRC) $(wildcard $(NATIVE_DIR)/src/*.zig)
	@mkdir -p $(PRIV_DIR)
	$(ZIG) build-lib -dynamic -fPIC -fallow-shlib-undefined $(ZIG_OPT) \
		-I$(ERL_INCLUDE_DIR) \
		-femit-bin=$(OUT) \
		$(SRC)

.PHONY: copy_to_mix_priv
copy_to_mix_priv: $(OUT)
	@if [ -n "$(MIX_APP_PATH)" ]; then \
		mkdir -p "$(MIX_PRIV_DIR)"; \
		if [ "$$(realpath "$(PRIV_DIR)")" != "$$(realpath "$(MIX_PRIV_DIR)")" ]; then \
			cp "$(OUT)" "$(MIX_PRIV_DIR)/"; \
		fi; \
	fi

clean:
	rm -f $(OUT)
	@if [ -n "$(MIX_APP_PATH)" ]; then \
		rm -f "$(MIX_PRIV_DIR)/$(NIF_NAME).so"; \
	fi
