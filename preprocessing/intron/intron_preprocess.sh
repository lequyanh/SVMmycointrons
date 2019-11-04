#!/bin/bash

# System settings:
#  - path to python
PYTHON=~/anaconda3/envs/mykointron/bin/python
#  - number of CPUs to be used in total
#    the minimal value is 2, although 16 or more is recommended
NUMBER_CPUS=10
#  - memory limit for caching (in MB)
#    this is used in the intron prediction
CACHE_LIMIT=1024
# -------------------------------------------------------------

# Pipeline settings:
#  - splice site dimers
DONOR="GT"
ACCEPTOR="AG"
#  - window size used when extracting splice sites sequences
#    the size is equal to the size of window used to train the models
DONOR_LWINDOW=70
DONOR_RWINDOW=70
ACCEPTOR_LWINDOW=70
ACCEPTOR_RWINDOW=70

# Number of scaffolds taken from each shroom for intron model training
NO_SCAFF=5
#  - range of intron lengths
#    considered when extracting introns from the positions of the positively classified splice sites
INTRON_MIN_LENGTH=10
INTRON_MAX_LENGTH=600
#  - order of the spectrum kernel
#    it is used in the intron prediction and it must be equal to the order used while training
SPECT_KERNEL_ORDER=2
#  - names of the splice site datasets
#    it will be created before the splice sites classification
DONOR_FILE="splice-site-donor-dataset.csv"
ACCEPTOR_FILE="splice-site-acceptor-dataset.csv"
#  - names of the files for splice site classification results
DONOR_RESULT="splice-site-donor-result.csv"
ACCEPTOR_RESULT="splice-site-acceptor-result.csv"
#  - name of the file that contains positions of alleged introns
#    it will be created after the splice sites classification
INTRON_POSITIONS_FILE="intron-positions-dataset.csv"
#  - name of the file that contains extracted intron sequences
INTRON_FILE="intron-dataset.csv"
#  - name of the file for intron classification results
INTRON_RESULT="intron-result.csv"

# -------------------------------------------------------------

# Derived variables:
# regex used to determine splice site sequences
donor_regex=";[ACGT]{$DONOR_LWINDOW}$DONOR[ACGT]{$DONOR_RWINDOW}$"
acceptor_regex=";[ACGT]{$ACCEPTOR_LWINDOW}$ACCEPTOR[ACGT]{$ACCEPTOR_RWINDOW}$"
# regex to filter positively classified splice sites
positive_splice_sites=";1$"
# regex to filter positively classified introns
positive_introns=";1$"
# -------------------------------------------------------------

# Pipeline inputs:
#  - Assembly file (FASTA)
assembly_filepath=$1
#  - donor splice site prediction model
splice_site_donor_model=$2
#  - acceptor splice site prediction model
splice_site_acceptor_model=$3
#  - intron prediction model
intron_model=$4

if [ $# -ne 4 ]
then
    echo "Arguments expected: ASSEMBLY DONOR_MODEL ACCEPTOR_MODEL INTRON_MODEL"
    exit 1
fi

# -------------------------------------------------------------

# The process (roughly):
#  1. Find all donors (GT) and use them to create a donor dataset.
#  2. Find all acceptors (AG) and use them to create an acceptor dataset.
#  3. Run two classification tasks in parallel:
#     a) classify donors (given the donor dataset),
#     b) classify acceptors (given the acceptor dataset).
#  4. Wait until both the classification tasks finish. Then find all possible pairs GT-AG given
#     positively classified donors and acceptors, and use them to create an intron dataset.
#  5. Run a classification task to identify introns.
# -------------------------------------------------------------

# exit after any error
set -e
# enable pipe fail
set -o pipefail

echo "Extracting donors and acceptors from [$assembly_filepath]..."

# prepare files for the donor and acceptor datasets
echo "scaffold;position;sequence" > $DONOR_FILE
echo "scaffold;position;sequence" > $ACCEPTOR_FILE

# extract the splice site sequences and then use awk to separate the sequences into
# the donor and acceptor dataset, respectively
$PYTHON extract-donor-acceptor.py $assembly_filepath \
                                  $DONOR $ACCEPTOR \
                                  $DONOR_LWINDOW $DONOR_RWINDOW \
                                  $ACCEPTOR_LWINDOW $ACCEPTOR_RWINDOW \
                                  $NO_SCAFF \
        | gawk -v donor=$donor_regex \
              -v acceptor=$acceptor_regex \
              -v donor_file=$DONOR_FILE \
              -v acceptor_file=$ACCEPTOR_FILE \
              '$0 ~ donor {print >> donor_file} $0 ~ acceptor {print >> acceptor_file}'

echo "Donors extracted to [$DONOR_FILE]."
echo "Acceptors extracted to [$ACCEPTOR_FILE]."
echo ""

# determine the number of CPUs available for each classification task
donor_cpus=$((NUMBER_CPUS/2))
acceptor_cpus=$((NUMBER_CPUS-donor_cpus))

echo "Starting classification of splice sites with [$donor_cpus/$acceptor_cpus] CPUs..."

# prepare files for the donor and acceptor classification results
echo "scaffold;position" > $DONOR_RESULT
echo "scaffold;position" > $ACCEPTOR_RESULT

# classify the donors and acceptors in parallel
# keep only the positively classified samples
# keep only the columns `scaffold`, and `position` (1st and 2nd)
$PYTHON classify-splice-sites.py $DONOR_FILE $splice_site_donor_model \
                                $DONOR_RWINDOW $DONOR_LWINDOW \
                                "donor" \
                                -c $donor_cpus \
        | grep $positive_splice_sites \
        | cut -d ';' -f -2 >> $DONOR_RESULT &
classify_donor_pid=$!
$PYTHON classify-splice-sites.py $ACCEPTOR_FILE $splice_site_acceptor_model \
                                $ACCEPTOR_LWINDOW $ACCEPTOR_RWINDOW \
                                "acceptor" \
                                -c $acceptor_cpus \
        | grep $positive_splice_sites \
        | cut -d ';' -f -2 >> $ACCEPTOR_RESULT &
classify_acceptor_pid=$!

# wait for both the classification tasks to finish
wait $classify_donor_pid $classify_acceptor_pid