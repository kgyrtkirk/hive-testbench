#!/bin/bash

SCALE=2
BASE_DIR=run.${SCALE}
HIVE_URI="jdbc:hive2://localhost:10000/tpcds_bin_partitioned_orc_${SCALE}"

mkdir -p $BASE_DIR


ls sample-queries-tpcds/|grep query|grep sql$|while read q;do
	N="${q/.sql}"
	D="$BASE_DIR/$N"
	mkdir -p "$D"
	cp sample-queries-tpcds/$q $D/query.sql
	(echo explain ; cat $D/query.sql) > $D/explain.sql
	(echo explain reoptimization ; cat $D/query.sql) > $D/explain_reopt.sql
	cp sample-queries-tpcds/a1.sql $D/init.sql

cat > $D/Makefile <<EOF

all:	query.run explain.run explain_reopt.run

%.run:	%.sql
	beeline -u '$HIVE_URI' -n hive -i init.sql -f $< > \$@
EOF
	

done


cat > $BASE_DIR/Makefile <<EOF
SUBDIRS := \$(wildcard */.)

all: \$(SUBDIRS)
\$(SUBDIRS):
	\$(MAKE) -C \$@

.PHONY: all \$(SUBDIRS)
EOF
