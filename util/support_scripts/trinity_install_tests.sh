#!/bin/bash

echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo ""
echo 'Performing Unit Tests of Build'
echo ' '
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"


if [ -e "Inchworm/bin/inchworm" ]
then
	echo "Inchworm:                has been Installed Properly"
else
	echo "Inchworm Installation appears to have FAILED"
fi
if [ -e "Chrysalis/bin/Chrysalis" ]
then
	echo "Chrysalis:               has been Installed Properly"
else
	echo "Chrysalis Installation appears to have FAILED"
fi
if [ -e "Chrysalis/bin/QuantifyGraph" ]
then
	echo "QuantifyGraph:           has been Installed Properly"
else
	echo "QuantifyGraph Installation appears to have FAILED"
fi

if [ -e "Chrysalis/bin/GraphFromFasta" ]
then
	echo "GraphFromFasta:          has been Installed Properly"
else
	echo "GraphFromFasta Installation appears to have FAILED"
fi

if [ -e "Chrysalis/bin/ReadsToTranscripts" ]
then
	echo "ReadsToTranscripts:      has been Installed Properly"
else
	echo "ReadsToTranscripts Installation appears to have FAILED"
fi


if [ -e "trinity-plugins/BIN/ParaFly" ]
then
	echo "parafly:                 has been Installed Properly"
else
	echo "parafly Installation appears to have FAILED"
fi

for rust_bin in sam_to_read_coords frag_coords_from_read_coords fragment_coverage_writer \
                define_coverage_partitions extract_reads_per_partition \
                ordered_fragment_coords_to_jaccard
do
	if [ -x "rust_bio_utils/target/release/$rust_bin" ]
	then
		printf "%-40s has been Installed Properly\n" "$rust_bin:"
	else
		printf "%-40s appears to have FAILED (Perl fallback will be used)\n" "$rust_bin Installation"
	fi
done

