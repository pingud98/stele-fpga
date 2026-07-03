# STELE FPGA — top-level flow. `source env.sh` first (created by make setup).
# `make all` from a clean checkout reproduces goldens, sims and bitstream.

RTL_CORE = rtl/tt_um_stele_ssm.v rtl/sequencer.v rtl/csr.v rtl/regfile.v \
           rtl/addr_gen.v rtl/hyperbus_phy.v rtl/ternary_mac.v \
           rtl/scan_alu.v rtl/mult_synth.v rtl/pwl_nonlin.v
RTL_FPGA = fpga/top_icebreaker.v $(RTL_CORE)
SIM_TESTS = dq_loopback phy datapath top_layer top_full

.PHONY: setup golden lint sim sim-all synth pnr timing bitstream report all \
        $(addprefix sim-,$(SIM_TESTS))

setup:
	./scripts/setup_toolchain.sh

golden:
	python3 golden/reference_model.py
	cd golden && python3 -m pytest test_reference.py -q

lint:
	verilator --lint-only -Wall -Irtl $(RTL_CORE) --top-module tt_um_stele_ssm

# static pattern rule: .PHONY targets do not match implicit `sim-%` rules
$(addprefix sim-,$(SIM_TESTS)): sim-%: lint
	$(MAKE) -C sim/tb TEST=$*

sim-all: $(addprefix sim-,$(SIM_TESTS))
sim: sim-all

build:
	mkdir -p build

synth: build lint
	yosys -q -p "read_verilog -Irtl -DICE40 -DCSR_LITE $(RTL_FPGA); \
	  synth_ice40 -top top_icebreaker -json build/stele.json" \
	  -l build/synth.log
	@grep -A 30 "=== top_icebreaker ===" build/synth.log || true

pnr: build
	nextpnr-ice40 --up5k --package sg48 --json build/stele.json \
	  --pcf fpga/icebreaker.pcf --asc build/stele.asc \
	  --freq 3 --report build/pnr_report.json -l build/pnr.log

timing: build
	icetime -d up5k -P sg48 -c 3 -t -r build/timing.rpt build/stele.asc
	@cat build/timing.rpt

bitstream: build
	icepack build/stele.asc build/stele.bin
	@ls -la build/stele.bin

report:
	@echo "see REPORT.md"

all: golden lint sim-all synth pnr timing bitstream
