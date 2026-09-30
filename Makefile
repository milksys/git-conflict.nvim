NVIM ?= nvim
MINI_PATH := deps/mini.nvim

.PHONY: test test-file deps fmt lint clean

test: deps
	$(NVIM) --headless --noplugin -u scripts/minimal_init.lua -c "lua MiniTest.run()"

# make test-file FILE=tests/test_parser.lua
test-file: deps
	$(NVIM) --headless --noplugin -u scripts/minimal_init.lua -c "lua MiniTest.run_file('$(FILE)')"

deps: $(MINI_PATH)

$(MINI_PATH):
	@mkdir -p deps
	git clone --filter=blob:none --depth 1 https://github.com/echasnovski/mini.nvim $(MINI_PATH)

fmt:
	stylua lua tests scripts

lint:
	stylua --check lua tests scripts

clean:
	rm -rf deps
