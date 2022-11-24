.PHONY: all run_flexkv run_gups run_gapbs run_bt \
	run_bg_dram_base run_bg_hw_tier run_bg_sw_tier

default: all

# <----------------------------- BUILD COMMANDS -----------------------------> 

RES ?= ./results

# Command to make sure all apps and hemem are compiled
all: ${RES} ./Hoard/src/libhoard.so ./src/libhemem.so \
	./microbenchmarks/gups ./microbenchmarks/gups-pebs

./Hoard/src/libhoard.so: 
	cd Hoard/src; $(MAKE)

./src/libhemem.so: ./Hoard/src/libhoard.so
	cd src; $(MAKE);

./microbenchmarks/gups:
	cd microbenchmarks; $(MAKE);

./microbenchmarks/gups-pebs:
	cd microbenchmarks; $(MAKE);

${RES}:
	mkdir -p ${RES};

# <------------------------------ RUN COMMANDS ------------------------------> 

NUMA_CMD := numactl -N0 -m0

# Configs for HeMem
NVMSIZE    ?= $$((512*1024*1024*1024))
DRAMSIZE   ?= $$((128*1024*1024*1024))
NVMOFFSET  ?= 0
DRAMOFFSET ?= 0

# Configs for app runs
FLEXKV_CPUS ?= 0-3
APP_CPUS    ?= 4-20
APP_THDS    ?= 16

FLEXKV_SIZE ?= $$((256*1024*1024*1024))
GUPS_SIZE   ?= $$((256*1024*1024*1024))
GAPBS_SIZE  ?= $$((256*1024*1024*1024))
BT_SIZE     ?= $$((168*1024*1024*1024))

# Commands needed by HeMem
SETUP_CMD = export LD_LIBRARY_PATH=./src:./Hoard/src:$LD_LIBRARY_PATH; \
	echo 1000000 > /proc/sys/vm/max_map_count;
PRELOAD  ?= LD_PRELOAD=./src/libhemem.so

FLEXKV_NICE ?= nice -20
# TODO: Command to run flexkv
run_flexkv: all
	# NVMSIZE=${NVMSIZE} DRAMSIZE=${DRAMSIZE} \
	# NVMOFFSET=${NVMOFFSET} DRAMOFFSET=${DRAMOFFSET} \
	# ${PRELOAD} ${FLEXKV_NICE} ${NUMA_CMD} --physcpubind=${FLEXKV_CPUS} \
	#	./run_flexkv >> ${RES}/${PREFIX}_flexkv.txt;

GUPS_ITERS ?= 1000000000
run_gups: all
	log_size=$$(printf "%.0f" $$(echo "l(${APP_SIZE})/l(2)"|bc -l)); \
	${NUMA_CMD} --physcpubind=${APP_CPUS} \
		./microbenchmarks/gups ${APP_THDS} ${GUPS_ITERS} $${log_size} \
		8 $${log_size} >> ${RES}/${PREFIX}_gups.txt;

run_gups_pebs: all
	log_size=$$(printf "%.0f" $$(echo "l(${APP_SIZE})/l(2)"|bc -l)); \
	NVMSIZE=${NVMSIZE} DRAMSIZE=${DRAMSIZE} \
	NVMOFFSET=${NVMOFFSET} DRAMOFFSET=${DRAMOFFSET} \
	${PRELOAD} ${NUMA_CMD} --physcpubind=${APP_CPUS} \
		./microbenchmarks/gups-pebs ${APP_THDS} ${GUPS_ITERS} \
		$${log_size} 8 $${log_size} >> ${RES}/${PREFIX}_gups_pebs.txt;

# TODO: Command to run GapBS
run_gapbs: all
	# NVMSIZE=${NVMSIZE} DRAMSIZE=${DRAMSIZE} \
	#	NVMOFFSET=${NVMOFFSET} DRAMOFFSET=${DRAMOFFSET} \
	#	${PRELOAD} ${NUMA_CMD} --physcpubind=${APP_CPUS} \
	#	./gapbs >> ${RES}/${PREFIX}_gapbs.txt;

# TODO: Command to run BT
run_bt: all
	# NVMSIZE=${NVMSIZE} DRAMSIZE=${DRAMSIZE} \
	#	NVMOFFSET=${NVMOFFSET} DRAMOFFSET=${DRAMOFFSET} \
	#	${PRELOAD} ${NUMA_CMD} --physcpubind=${APP_CPUS} \
	#	./bt >> ${RES}/${PREFIX}_bt.txt;

run_bg_dram_base: all
	PREFIX=bg_dram_base; \
	APP_SIZE=$$((64*1024*1024*1024)); \
	$(MAKE) run_gups APP_SIZE=$${APP_SIZE} PREFIX=$${PREFIX} & \
	$(MAKE) run_flexkv PRELOAD="" FLEXKV_SIZE=$${APP_SIZE} PREFIX=$${PREFIX}_gups; \
	wait; \
	$(MAKE) run_gapbs PRELOAD="" APP_SIZE=$${APP_SIZE} PREFIX=$${PREFIX} & \
	$(MAKE) run_flexkv PRELOAD="" FLEXKV_SIZE=$${APP_SIZE} PREFIX=$${PREFIX}_gapbs; \
	wait; \
	$(MAKE) run_bt PRELOAD="" APP_SIZE=$${APP_SIZE} PREFIX=$${PREFIX} & \
	$(MAKE) run_flexkv PRELOAD="" FLEXKV_SIZE=$${APP_SIZE} PREFIX=$${PREFIX}_bt; \
	wait; \

run_bg_hw_tier: all
	PREFIX=bg_hw_tier; \
	$(MAKE) run_gups APP_SIZE=${GUPS_SIZE} PREFIX=$${PREFIX} & \
	$(MAKE) run_flexkv PRELOAD="" PREFIX=$${PREFIX}_gups; \
	wait; \
	$(MAKE) run_gapbs PRELOAD="" APP_SIZE=${GAPBS_SIZE} PREFIX=$${PREFIX} & \
	$(MAKE) run_flexkv PRELOAD="" PREFIX=$${PREFIX}_gapbs; \
	wait; \
	$(MAKE) run_bt PRELOAD="" APP_SIZE=${BT_SIZE} PREFIX=$${PREFIX} & \
	$(MAKE) run_flexkv PRELOAD="" PREFIX=$${PREFIX}_bt; \
	wait; \

# FlexKV occupies first half of DRAM/NVM, and other app the other half
run_bg_sw_tier: all
	# HeMem runs
	NVMSIZE=$$((${NVMSIZE}/2)); DRAMSIZE=$$((${DRAMSIZE}/2)); \
	${SETUP_CMD} \
	PREFIX=bg_hemem; \
	$(MAKE) run_gups_pebs NVMSIZE=$${NVMSIZE} DRAMSIZE=$${DRAMSIZE} \
		NVMOFFSET=$${NVMSIZE} DRAMOFFSET=$${DRAMSIZE} \
		APP_SIZE=${GUPS_SIZE} PREFIX=$${PREFIX} & \
	$(MAKE) run_flexkv NVMSIZE=$${NVMSIZE} DRAMSIZE=$${DRAMSIZE} \
		NVMOFFSET=0 DRAMOFFSET=0 PREFIX=$${PREFIX}_gups; \
	wait; \
	$(MAKE) run_gapbs NVMSIZE=$${NVMSIZE} DRAMSIZE=$${DRAMSIZE} \
		NVMOFFSET=$${NVMSIZE} DRAMOFFSET=$${DRAMSIZE} \
		APP_SIZE=${GAPBS_SIZE} PREFIX=$${PREFIX} & \
	$(MAKE) run_flexkv NVMSIZE=$${NVMSIZE} DRAMSIZE=$${DRAMSIZE} \
		NVMOFFSET=0 DRAMOFFSET=0 PREFIX=$${PREFIX}_gapbs; \
	wait; \
	$(MAKE) run_bt NVMSIZE=$${NVMSIZE} DRAMSIZE=$${DRAMSIZE} \
		NVMOFFSET=$${NVMSIZE} DRAMOFFSET=$${DRAMSIZE} \
		APP_SIZE=${BT_SIZE} PREFIX=$${PREFIX} & \
	$(MAKE) run_flexkv NVMSIZE=$${NVMSIZE} DRAMSIZE=$${DRAMSIZE} \
		NVMOFFSET=0 DRAMOFFSET=0 PREFIX=$${PREFIX}_bt; \
	wait; \
	# TODO: zNUMA runs
	PREFIX=bg_znuma;