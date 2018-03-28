#!/bin/bash

function usage {
	echo "Usage: tpcds-setup.sh scale_factor [temp_directory]"
	exit 1
}

function runcommand {
	if [ "X$DEBUG_SCRIPT" != "X" ]; then
		$1
	else
		$1 2>/dev/null
	fi
}

if [ ! -f tpcds-gen/target/tpcds-gen-1.0-SNAPSHOT.jar ]; then
	echo "Please build the data generator with ./tpcds-build.sh first"
	exit 1
fi
which beeline > /dev/null 2>&1
if [ $? -ne 0 ]; then
	echo "Script must be run where Hive is installed"
	exit 1
fi

# Tables in the TPC-DS schema.
DIMS="date_dim time_dim item customer customer_demographics household_demographics customer_address store promotion warehouse ship_mode reason income_band call_center web_page catalog_page web_site"
FACTS="store_sales store_returns web_sales web_returns catalog_sales catalog_returns inventory"

# Get the parameters.
SCALE=$1
DIR=$2
if [ "X$BUCKET_DATA" != "X" ]; then
	BUCKETS=13
	RETURN_BUCKETS=13
else
	BUCKETS=1
	RETURN_BUCKETS=1
fi
if [ "X$DEBUG_SCRIPT" != "X" ]; then
	set -x
fi

# Sanity checking.
if [ X"$SCALE" = "X" ]; then
	usage
fi
if [ X"$DIR" = "X" ]; then
	DIR=/tmp/tpcds-generate
fi
if [ $SCALE -eq 1 ]; then
	echo "Scale factor must be greater than 1"
	exit 1
fi

# Do the actual data load.
hdfs dfs -mkdir -p ${DIR}
hdfs dfs -ls ${DIR}/${SCALE} > /dev/null
if [ $? -ne 0 ]; then
	echo "Generating data at scale factor $SCALE."
	(cd tpcds-gen; hadoop jar target/*.jar -d ${DIR}/${SCALE}/ -s ${SCALE})
fi
hdfs dfs -ls ${DIR}/${SCALE} > /dev/null
if [ $? -ne 0 ]; then
	echo "Data generation failed, exiting."
	exit 1
fi
echo "TPC-DS text data generation complete."

# Create the text/flat tables as external tables. These will be later be converted to ORCFile.
echo "Loading text data into external tables."

beeline="beeline -u jdbc:hive2://localhost:10000/ -n hive"
function render() { eval "echo \"$(cat $1)\""; }

DB="tpcds_text_${SCALE}" LOCATION="${DIR}/${SCALE}" render ddl-tpcds/text/alltables.sql > .q.sql
runcommand "$beeline -i settings/load-flat.sql -f .q.sql"
echo "loaded$?"

# Create the partitioned and bucketed tables.
if [ "X$FORMAT" = "X" ]; then
	FORMAT=orc
fi

SILENCE="2> /dev/null 1> /dev/null" 
if [ "X$DEBUG_SCRIPT" != "X" ]; then
	SILENCE=""
fi

i=1
total=24
DATABASE=tpcds_bin_partitioned_${FORMAT}_${SCALE}
MAX_REDUCERS=2500 # maximum number of useful reducers for any scale 
REDUCERS=$((test ${SCALE} -gt ${MAX_REDUCERS} && echo ${MAX_REDUCERS}) || echo ${SCALE})

D="load.${SCALE}"
mkdir -p $D
TARGETS=""

for t in ${DIMS} ${FACTS}
do
	TARGETS+=" .loaded.$t"
	
	DB=tpcds_bin_partitioned_${FORMAT}_${SCALE}	\
	SCALE=${SCALE} 					\
	SOURCE=tpcds_text_${SCALE}			\
	BUCKETS=${BUCKETS}				\
	RETURN_BUCKETS=${RETURN_BUCKETS}		\
	REDUCERS=${REDUCERS}				\
	FILE="${FORMAT} TBLPROPERTIES ('transactional'='false')"	\
	render ddl-tpcds/bin_partitioned/${t}.sql > "$D/load.$t.sql"

	echo "analyze table tpcds_text_${SCALE}.$t compute statistics for columns;" > "$D/analyze.text.$t.sql"
	echo "analyze table tpcds_bin_partitioned_orc_${SCALE}.$t compute statistics for columns;" > "$D/analyze.orc.$t.sql"

done

cat > "$D/Makefile" << EOF 
all:	$TARGETS

.loaded.%:	.load.% 
	touch \$@

.load.%:	load.%.sql      .analyze.text.%
	$beeline -i ../settings/load-partitioned.sql -f \$<
	touch \$@

.analyze.%:	analyze.%.sql
	$beeline -i ../settings/load-partitioned.sql -f \$<
	touch \$@

EOF


#runcommand "$beeline -i settings/load-partitioned.sql -f $BLS"
echo "ec: $?"
echo "Data loaded into database ${DATABASE}."

