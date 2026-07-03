# cocotb test runner. Usage: make TEST=dq_loopback   (source ../../env.sh first)
TOPLEVEL_LANG = verilog
SIM ?= icarus
TEST ?= dq_loopback

REPO := $(abspath $(CURDIR)/../..)
RTL  := $(REPO)/rtl
SIMD := $(REPO)/sim

VERILOG_SOURCES_dq_loopback = $(RTL)/hyperbus_dq_io.v $(SIMD)/tb/tb_dq_loopback.v
VERILOG_SOURCES_phy = $(RTL)/hyperbus_phy.v $(SIMD)/hyperram_model.v $(SIMD)/tb/tb_phy.v
VERILOG_SOURCES_datapath = $(RTL)/mult_synth.v $(RTL)/ternary_mac.v $(RTL)/scan_alu.v $(RTL)/pwl_nonlin.v $(SIMD)/tb/tb_datapath.v
CORE_SOURCES = $(RTL)/tt_um_stele_ssm.v $(RTL)/sequencer.v $(RTL)/csr.v $(RTL)/regfile.v $(RTL)/addr_gen.v $(RTL)/hyperbus_phy.v $(RTL)/ternary_mac.v $(RTL)/scan_alu.v $(RTL)/mult_synth.v $(RTL)/pwl_nonlin.v
VERILOG_SOURCES_top_layer = $(CORE_SOURCES) $(SIMD)/hyperram_model.v $(SIMD)/tb/tb_top.v
VERILOG_SOURCES_top_full = $(CORE_SOURCES) $(SIMD)/hyperram_model.v $(SIMD)/tb/tb_top.v
COMPILE_ARGS += -I$(RTL)

VERILOG_SOURCES = $(VERILOG_SOURCES_$(TEST))
ifneq (,$(filter top_layer top_full,$(TEST)))
COCOTB_TOPLEVEL = tb_top
else
COCOTB_TOPLEVEL = tb_$(TEST)
endif
COCOTB_TEST_MODULES = test_$(TEST)
SIM_BUILD = sim_build/$(TEST)
COMPILE_ARGS += -g2012
export PYTHONPATH := $(SIMD)/tb:$(REPO)/golden:$(PYTHONPATH)

include $(shell cocotb-config --makefiles)/Makefile.sim
