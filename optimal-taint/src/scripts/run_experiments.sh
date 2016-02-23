#!/usr/bin/env bash

# TODO: make this self-contained (i.e. project should download phosphor and build etc)
# Parse in arguments
if [ $# -ne 6 ]
 then
    #echo "Usage: ./run_experiments.sh <phosphor-target> <num-files> <num-vars> <min-lens> <generated-dir> <results-dir>"
    echo "Usage: ./run_experiments.sh <phosphor-target> <num-files> <num-vars> <min-lens> <generated-dir> <results-dir>"
    echo "phosphor-target: phosphor target folder, as created by calling mvn package; mvn verify; in the phosphor project"
    echo "num-files: number of files to generate for each iteration of test"
    echo "num-vars: quoted, space-separated list of number of variables for experiments"
    echo "min-lens: quoted, space-separated list of minimum number of commands for experiments"
    echo "generated-dir: directory used to create random programs"
    echo "results-dir: output directory for results"
    exit 1
fi

# User arguments
phosphor_target=$(readlink -f $1)
num_files=$2
num_vars=$3
min_lens=$4
gen_dir=$5
results_dir=$6
# minimum number of executed commands in a randomly generated program
# needed to avoid programs that do next to nothing (and result in caliper exceptions)
MIN_CMD=500

SCRIPTS_DIR=$(dirname $(readlink -f $0))

# Resources needed
phosphor_jar=$(find $phosphor_target -iname "Phosphor-[0-9]*SNAPSHOT.jar" | xargs -I {} readlink -f {})
instrumented_jre=$(readlink -f ${phosphor_target}/jre-inst-obj/)
caliper_jar=$(readlink -f ~/.m2/repository/com/google/caliper/caliper/0.5-rc1/caliper-0.5-rc1.jar)
optimal_taint_jar=$(readlink -f $SCRIPTS_DIR/../../target/optimal-taint-1.0-SNAPSHOT.jar)

# Create results folder
mkdir -p $results_dir
# File holding counts data
counts_results_file=$(readlink -f results/counts.csv)
caliper_results_file_stub=$(readlink -f results/caliper_results)
results_file=$(readlink -f results/results.csv)


# Count nuber of lines and trim unnecessary text
# Args: file
function count_lines {
 wc -l $1 | awk '{print $1}'
}

# Count number of bytecode instructions (1 line = 1 instruction) in java .class file
# Args: file
function count_instructions {
  javap -c $1 | count_lines
}

# Run a java file with appropriate JRE etc (so instrumented get run with phosphor-instrumented executables)
# Args: folder for classpath, and class name
function run {
  if [[ $2 == *_none ]]
    then
      java -cp $1 $2
    else
      $instrumented_jre/bin/java -cp $phosphor_jar:$1 -Xbootclasspath/a:$phosphor_jar -javaagent:$phosphor_jar $2
  fi
}

function mk_clean_dirs {
 # clean up existing folders
 rm -rf $gen_dir/
 # Create necessary folders for compilation/instrumentation
 mkdir -p $gen_dir/orig_compiled/ $gen_dir/inst_compiled/
}

# Generate files using java and compile/instrument as necessary
# Args: number of variables, minimum number of commands
function generate_files_and_compile {
  java -cp $optimal_taint_jar com.github.OptimalTaint.Generate $num_files $1 $2 $MIN_CMD $gen_dir

  # Generate google caliper benchmark files
  java -cp $optimal_taint_jar com.github.OptimalTaint.CreateCaliperBenchmarks $gen_dir "Caliper"

  # Compile all files (random and benchmarks)
  javac -cp $caliper_jar:$phosphor_jar -d $gen_dir/orig_compiled/ $gen_dir/*.java

  # Instrument a copy of all files (random and benchmarks)
  java -jar $phosphor_jar -multiTaint $gen_dir/orig_compiled/ $gen_dir/inst_compiled/
}


# Run one iteration of experiments
# Args: number of variables, number of min commands, file for counts data, file stub name for caliper json results
function experiments0 {
local var_ct=$1
local min_cmd_ct=$2
local ct_file=$3
local caliper_file_stub=$4

# file header
echo "name,declaration_count,generated_command_min_count,instruction_count,branches_exec_count" > $ct_file
## For each randomly generated program (except benchmark files) count important stats
for java_file in $(find $gen_dir -type f -name "P*.java" -exec basename {} ';')
do
  # trim file ending
  name=${java_file%.*}
  # choose directory to use based on file name
  if [[ $name == *_none ]]
    then
      dir=$gen_dir/orig_compiled/
    else
      dir=$gen_dir/inst_compiled/
  fi
  # add name of source file
  echo -n $name >> $ct_file
  echo -n "," >> $ct_file
  # count number of variable declarations in original file
  echo -n $var_ct >> $ct_file
  echo -n "," >> $ct_file
  # minimum number of commands (as specified for generation step)
  echo -n $min_cmd_ct >> $ct_file
  echo -n "," >> $ct_file
  # count number of bytecode instructions
  echo -n $(count_instructions $dir/$name.class) >> $ct_file
  echo -n "," >> $ct_file
  # count number of branches actually executed
  echo $(run $dir $name) >> $ct_file
done


## Caliper benchmark files
# Execution and memory (TODO: memory) benchmarking
# No instrumentation
(cd $gen_dir/orig_compiled; $SCRIPTS_DIR/run_caliper.sh $phosphor_target Caliper_none --results ${caliper_file_stub}_none.json)
## Naive instrumentation
(cd $gen_dir/inst_compiled; $SCRIPTS_DIR/run_caliper.sh $phosphor_target Caliper_naive --instrumented --results ${caliper_file_stub}_naive.json)
}


# Main experiment loop
for num_var in $num_vars
do
  for min_len in $min_lens
  do
    echo "Running experiment with $num_var variables and $min_len minimum commands"
    mk_clean_dirs
    generate_files_and_compile $num_var $min_len
    experiments0 $num_var $min_len $counts_results_file $caliper_results_file_stub
    # combine results and append to total results file
    python $SCRIPTS_DIR/combine_results.py $counts_results_file $caliper_results_file_stub $results_file
  done
done