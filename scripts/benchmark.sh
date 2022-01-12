#! /usr/bin/zsh

KEEB=/dev/input/by-path/platform-i8042-serio-0-event-kbd
FLAMEGRAPH=$HOME/github/FlameGraph
INPUT=./sample10.keys

set -ex

# echo "- creating a sample INPUT file"
# sudo intercept -g $KEEB > sample.keys

function benchmark() {
    mode=$1
    csv=./layerz_benchmark.csv
    input_size=$(stat -c %s $INPUT)
    commit=$(git rev-parse HEAD)
    echo  "*** benchmark $mode ***"
    zig build -D$mode

    if [[ ! -f $csv ]] ; then
        echo "mode,commit,input_size,real_time,user_time,kernel_time,waits,mem,cpu" > $csv
    fi;
    format="$mode,$commit,$input_size,%e,%U,%S,%w,%M,%P"
    for i in {0..10..1}
    do
        /usr/bin/time -f $format -ao $csv ../zig-out/bin/layerz < $INPUT > /dev/null 2>&1;
    done
}

function flamegraph() {
    mode=$1
    echo  "*** flamegraph $mode ***"
    zig build -D$mode
    sudo perf record -F 99 -g -b -- ./sample_run.sh $INPUT
    if [[ -f $FLAMEGRAPH/stackcollapse-perf.pl ]] ; then
        sudo perf script | $FLAMEGRAPH/stackcollapse-perf.pl | $FLAMEGRAPH/flamegraph.pl > $mode.svg
    fi;
}

function summary() {

}

benchmark release-safe
flamegraph release-safe
benchmark release-small
flamegraph release-small
benchmark release-fast
flamegraph release-fast
