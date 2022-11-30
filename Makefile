.PHONY: all Hoard HeMem GUPS FlexKVS GAPBS\
	run_flexkvs run_gups run_gapbs run_bt \
	run_bg_dram_base run_bg_hw_tier run_bg_sw_tier \
	 

default: all

# <----------------------------- BUILD COMMANDS -----------------------------> 

RES ?= ./results

${RES}:
	mkdir -p ${RES};

# Command to make sure all apps and hemem are freshly compiled
all: ${RES} Hoard HeMem GUPS FlexKVS GAPBS

Hoard:
	cd Hoard/src; $(MAKE)

HeMem:
	cd src; $(MAKE);

GUPS:
	cd microbenchmarks; $(MAKE);

FlexKVS:
	cd apps/flexkvs; $(MAKE);

GAPBS:
	cd apps/gapbs; $(MAKE)

./Hoard/src/libhoard.so: 
	$(MAKE) Hoard

./src/libhemem.so: ./Hoard/src/libhoard.so
	$(MAKE) HeMem

./microbenchmarks/gups:
	$(MAKE) GUPS;

./microbenchmarks/gups-pebs:
	$(MAKE) GUPS;

./apps/flexkvs/flexkvs:
	$(MAKE) FlexKVS;

./apps/flexkvs/kvsbench:
	$(MAKE) FlexKVS;

./apps/gapbs/bc:
	$(MAKE) GAPBS;

# <------------------------------ RUN COMMANDS ------------------------------> 

BASE_NODE ?= 0
OTHER_NODE ?= $$(((${BASE_NODE} + 1) % 2))
NUMA_CMD ?= numactl -N${BASE_NODE} -m${BASE_NODE}
NUMA_CMD_CLIENT ?= numactl -N${OTHER_NODE} -m${OTHER_NODE}

CMD_KILL_ALL := \
	list_descendants () { \
		local children=$$(ps -o pid= --ppid "$$1"); \
		for pid in $${children}; \
		do \
			list_descendants "$${pid}"; \
		done; \
		echo "$${children}"; \
	}; \
	kill $$(list_descendants $$$$)


# Configs for HeMem
NVMSIZE    ?= $$((512*1024*1024*1024))
DRAMSIZE   ?= $$((128*1024*1024*1024))
NVMOFFSET  ?= 0
DRAMOFFSET ?= 0

# Configs for app runs
FLEXKV_THDS ?= 4
APP_THDS    ?= 16
ifeq (${BASE_NODE}, 1)
FLEXKV_CPUS ?= 24-28
APP_CPUS    ?= 29-47
else
FLEXKV_CPUS ?= 48-63
APP_CPUS    ?= 0-23
endif

FLEXKV_SIZE ?= $$((64*1024*1024*1024))
GUPS_SIZE   ?= $$((256*1024*1024*1024))
GAPBS_SIZE  ?= 28
BT_SIZE     ?= $$((168*1024*1024*1024))

# Commands needed by HeMem
SETUP_CMD = export LD_LIBRARY_PATH=./src:./Hoard/src:$LD_LIBRARY_PATH; \
	echo 1000000 > /proc/sys/vm/max_map_count;
PRELOAD  ?= LD_PRELOAD=./src/libhemem.so

FLEXKV_NICE ?= nice -20
FLEXKV_SERVER_WAIT ?= 60
FLEXKV_SAMPLE_TIME ?= 1200
FLEXKV_ZIPF ?= 0.99
# TODO: Can we somehow launch client after server is setup
# instead of waiting an arbitrary amount of time and hoping
# that the server is ready in that time?
run_flexkvs: ./apps/flexkvs/flexkvs ./apps/flexkvs/kvsbench
	-./apps/flexkvs/unlink_socks.sh; # Cleanup

	${PRELOAD} ${FLEXKV_NICE} ${NUMA_CMD} --physcpubind=${FLEXKV_CPUS} \
		./apps/flexkvs/flexkvs flexkvs.conf ${FLEXKV_THDS} ${FLEXKV_SIZE} & \
	sleep ${FLEXKV_SERVER_WAIT}; \
	${FLEXKV_NICE} ${NUMA_CMD_CLIENT} \
		./apps/flexkvs/kvsbench -t ${FLEXKV_THDS} -z ${FLEXKV_ZIPF} 127.0.0.1:11211 -S $$((5*${FLEXKV_SIZE}/8)) > ${RES}/${PREFIX}_flexkv.txt & \
	sleep ${FLEXKV_SAMPLE_TIME};\
	pkill -P $$$$;

GUPS_ITERS ?= 8000000000
run_gups: ./microbenchmarks/gups
	log_size=$$(printf "%.0f" $$(echo "l(${APP_SIZE})/l(2)"|bc -l)); \
	${NUMA_CMD} --physcpubind=${APP_CPUS} \
		./microbenchmarks/gups ${APP_THDS} ${GUPS_ITERS} $${log_size} \
		8 $${log_size} > ${RES}/${PREFIX}_gups.txt;

run_gups_pebs: ./microbenchmarks/gups-pebs
	log_size=$$(printf "%.0f" $$(echo "l(${APP_SIZE})/l(2)"|bc -l)); \
	NVMSIZE=${NVMSIZE} DRAMSIZE=${DRAMSIZE} \
	NVMOFFSET=${NVMOFFSET} DRAMOFFSET=${DRAMOFFSET} \
	${PRELOAD} ${NUMA_CMD} --physcpubind=${APP_CPUS} \
		./microbenchmarks/gups-pebs ${APP_THDS} ${GUPS_ITERS} \
		$${log_size} 8 $${log_size} > ${RES}/${PREFIX}_gups_pebs.txt;

GAPBS_TRIALS ?= 100
run_gapbs: ./apps/gapbs/bc
	NVMSIZE=${NVMSIZE} DRAMSIZE=${DRAMSIZE} NVMOFFSET=${NVMOFFSET} \
	DRAMOFFSET=${DRAMOFFSET} OMP_THREAD_LIMIT=${APP_THDS} \
	${PRELOAD} ${NUMA_CMD} --physcpubind=${APP_CPUS} \
		./apps/gapbs/bc -n ${GAPBS_TRIALS} -g ${APP_SIZE} > ${RES}/${PREFIX}_gapbs.txt;

# TODO: Command to run BT
run_bt: 
	# NVMSIZE=${NVMSIZE} DRAMSIZE=${DRAMSIZE} \
	#	NVMOFFSET=${NVMOFFSET} DRAMOFFSET=${DRAMOFFSET} \
	#	${PRELOAD} ${NUMA_CMD} --physcpubind=${APP_CPUS} \
	#	./bt > ${RES}/${PREFIX}_bt.txt;

run_bg_dram_base: all
	PREFIX=bg_dram_base; \
	BASE_NODE=1;\
	APP_SIZE=$$((64*1024*1024*1024)); \
	$(MAKE) run_flexkvs BASE_NODE=$${BASE_NODE} PRELOAD="" \
		FLEXKV_SIZE=$${APP_SIZE} PREFIX=$${PREFIX}_alone; \
	wait;\
	$(MAKE) run_flexkvs BASE_NODE=$${BASE_NODE} PRELOAD="" \
		FLEXKV_SIZE=$${APP_SIZE} PREFIX=$${PREFIX}_gups & \
	$(MAKE) run_gups BASE_NODE=$${BASE_NODE} APP_SIZE=$${APP_SIZE} PREFIX=$${PREFIX}; \
	wait;\
	$(MAKE) run_flexkvs BASE_NODE=$${BASE_NODE} PRELOAD="" \
		FLEXKV_SIZE=$${APP_SIZE} PREFIX=$${PREFIX}_gapbs & \
	$(MAKE) run_gapbs BASE_NODE=$${BASE_NODE} PRELOAD="" APP_SIZE=27 PREFIX=$${PREFIX}; \
	wait;\
	#$(MAKE) run_flexkvs BASE_NODE=$${BASE_NODE} PRELOAD=""\
	#	FLEXKV_SIZE=$${APP_SIZE} PREFIX=$${PREFIX}_bt & \
	#$(MAKE) run_bt BASE_NODE=$${BASE_NODE} PRELOAD="" APP_SIZE=$${APP_SIZE} PREFIX=$${PREFIX}; \
	#wait; \

run_bg_hw_tier: all
	PREFIX=bg_hw_tier; \
	FLEXKV_SIZE=$$((256*1024*1024*1024)); \
	$(MAKE) run_flexkvs FLEXKV_SIZE=$${FLEXKV_SIZE} PRELOAD="" PREFIX=$${PREFIX}_alone; \
	$(MAKE) run_flexkvs FLEXKV_SIZE=$${FLEXKV_SIZE} PRELOAD="" PREFIX=$${PREFIX}_gups & \
	$(MAKE) run_gups APP_SIZE=${GUPS_SIZE} PREFIX=$${PREFIX}; \
	wait; \
	$(MAKE) run_flexkvs FLEXKV_SIZE=$${FLEXKV_SIZE} PRELOAD="" PREFIX=$${PREFIX}_gapbs & \
	$(MAKE) run_gapbs PRELOAD="" APP_SIZE=${GAPBS_SIZE} PREFIX=$${PREFIX}; \
	wait; \
	#$(MAKE) run_bt PRELOAD="" APP_SIZE=${BT_SIZE} PREFIX=$${PREFIX} & \
	#$(MAKE) run_flexkvs FLEXKV_SIZE=$${FLEXKV_SIZE} PRELOAD="" PREFIX=$${PREFIX}_bt; \
	#wait;

# FlexKV occupies first half of DRAM/NVM, and other app the other half
run_bg_sw_tier: all
	# HeMem runs
	FLEXKV_SIZE=$$((256*1024*1024*1024)); \
	NVMSIZE=$$((${NVMSIZE}/2)); DRAMSIZE=$$((${DRAMSIZE}/2)); \
	${SETUP_CMD} \
	PREFIX=bg_hemem; \
	$(MAKE) run_flexkvs NVMSIZE=$${NVMSIZE} DRAMSIZE=$${DRAMSIZE} \
		NVMOFFSET=0 DRAMOFFSET=0 FLEXKV_SIZE=$${FLEXKV_SIZE} PREFIX=$${PREFIX}_alone; \
	$(MAKE) run_flexkvs NVMSIZE=$${NVMSIZE} DRAMSIZE=$${DRAMSIZE} \
		NVMOFFSET=0 DRAMOFFSET=0 FLEXKV_SIZE=$${FLEXKV_SIZE} PREFIX=$${PREFIX}_gups & \
	$(MAKE) run_gups_pebs NVMSIZE=$${NVMSIZE} DRAMSIZE=$${DRAMSIZE} \
		NVMOFFSET=$${NVMSIZE} DRAMOFFSET=$${DRAMSIZE} \
		APP_SIZE=${GUPS_SIZE} PREFIX=$${PREFIX}; \
	wait; \
	$(MAKE) run_flexkvs NVMSIZE=$${NVMSIZE} DRAMSIZE=$${DRAMSIZE} \
		NVMOFFSET=0 DRAMOFFSET=0 FLEXKV_SIZE=$${FLEXKV_SIZE} PREFIX=$${PREFIX}_gapbs & \
	$(MAKE) run_gapbs NVMSIZE=$${NVMSIZE} DRAMSIZE=$${DRAMSIZE} \
		NVMOFFSET=$${NVMSIZE} DRAMOFFSET=$${DRAMSIZE} \
		APP_SIZE=${GAPBS_SIZE} PREFIX=$${PREFIX}; \
	wait; \
	#$(MAKE) run_bt NVMSIZE=$${NVMSIZE} DRAMSIZE=$${DRAMSIZE} \
	#	NVMOFFSET=$${NVMSIZE} DRAMOFFSET=$${DRAMSIZE} \
	#	APP_SIZE=${BT_SIZE} PREFIX=$${PREFIX} & \
	#$(MAKE) run_flexkvs NVMSIZE=$${NVMSIZE} DRAMSIZE=$${DRAMSIZE} \
	#	NVMOFFSET=0 DRAMOFFSET=0 FLEXKV_SIZE=$${FLEXKV_SIZE} PREFIX=$${PREFIX}_bt; \
	#wait; \
	# TODO: zNUMA runs
	#PREFIX=bg_znuma;

# FlexKV occupies the entire DRAM and half of NVM, and other app the other half of NVM
run_test_bg_sw_tier: all
	# HeMem runs
	FLEXKV_SIZE=$$((256*1024*1024*1024)); \
	NVMSIZE=$$((${NVMSIZE}/2)); \
	${SETUP_CMD} \
	PREFIX=test_bg_hemem; \
	$(MAKE) run_flexkvs NVMSIZE=$${NVMSIZE} NVMOFFSET=0 FLEXKV_SIZE=$${FLEXKV_SIZE} PREFIX=$${PREFIX}_alone; \
	$(MAKE) run_flexkvs NVMSIZE=$${NVMSIZE} NVMOFFSET=0 FLEXKV_SIZE=$${FLEXKV_SIZE} PREFIX=$${PREFIX}_gups & \
	$(MAKE) run_gups_pebs NVMSIZE=$${NVMSIZE} DRAMSIZE=0 NVMOFFSET=$${NVMSIZE} DRAMOFFSET=$${DRAMSIZE} \
		APP_SIZE=${GUPS_SIZE} PREFIX=$${PREFIX}; \
	wait; \
	$(MAKE) run_flexkvs NVMSIZE=$${NVMSIZE} NVMOFFSET=0 FLEXKV_SIZE=$${FLEXKV_SIZE} PREFIX=$${PREFIX}_gapbs & \
	$(MAKE) run_gapbs NVMSIZE=$${NVMSIZE} DRAMSIZE=0 NVMOFFSET=$${NVMSIZE} DRAMOFFSET=$${DRAMSIZE} \
		APP_SIZE=${GAPBS_SIZE} PREFIX=$${PREFIX}; \
	wait; \

BG_PREFIXES = bg_dram_base bg_hemem test_bg_hemem
BG_APPS = alone gups gapbs
extract_bg: all
	for type in ${BG_PREFIXES}; do \
		printf "$${type}\nApp\tThroughput\tAvg latency\t95%% latency\t99%% latency\n"; \
		for app in ${BG_APPS}; do \
			printf "$${app}\t"; \
			data=$$(grep "TP: total=" ${RES}/$${type}_$${app}_flexkv.txt); \
			throughput=$$(echo $${data} | grep -oE "total=[0-9]+\.[0-9]+ mops" | grep -oE "[0-9]+\.[0-9]+"); \
			avg_lat=$$(echo $${data} | grep -oE "50p=[0-9]+ us" | grep -m2 -oE "[0-9]+" | tail -n1); \
			nine_five_lat=$$(echo $${data} | grep -oE "95p=[0-9]+ us" | grep -m2 -oE "[0-9]+" | tail -n1); \
			nine_nine_lat=$$(echo $${data} | grep -oE "99p=[0-9]+ us" | grep -m2 -oE "[0-9]+" | tail -n1); \
			sum=0; \
			counter=0; \
			for i in $${throughput}; do \
				sum=$$(echo "$${sum} + $$i" | bc -l);\
				counter=$$(($${counter} + 1)); \
			done; \
			printf "%.2f\t" $$(echo "$${sum} / $${counter}" | bc -l); \
			sum=0; \
			counter=0; \
			for i in $${avg_lat}; do \
				sum=$$(echo "$${sum} + $$i" | bc -l);\
				counter=$$(($${counter} + 1)); \
			done; \
			printf "%.2f\t" $$(echo "$${sum} / $${counter}" | bc -l); \
			sum=0; \
			counter=0; \
			for i in $${nine_five_lat}; do \
				sum=$$(echo "$${sum} + $$i" | bc -l);\
				counter=$$(($${counter} + 1)); \
			done; \
			printf "%.2f\t" $$(echo "$${sum} / $${counter}" | bc -l); \
			sum=0; \
			counter=0; \
			for i in $${nine_nine_lat}; do \
				sum=$$(echo "$${sum} + $$i" | bc -l);\
				counter=$$(($${counter} + 1)); \
			done; \
			printf "%.2f\n" $$(echo "$${sum} / $${counter}" | bc -l); \
		done; \
	done