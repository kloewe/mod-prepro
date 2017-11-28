#!/bin/bash
#-----------------------------------------------------------------------------
# Preprocessing of anatomical (T1) images
#
# - reorient to MNI152 orientation   (fslreorient2std)
# - brain extraction                 (bet or optiBET)
# - bias field correction            (fast)
# - tissue-type segmentation         (fast)
# - registration to MNI152 space     (flirt and fnirt)
#
# External dependencies:
# FSL      (https://fsl.fmrib.ox.ac.uk/fsl/fslwiki/FSL)
# optiBET  (https://montilab.psych.ucla.edu/fmri-wiki/optibet)
#
# Author: Kristian Loewe
#-----------------------------------------------------------------------------
set -e

# --- functions
usage() {
  echo "Usage: `basename $0` fname outdir [options]"
  echo ""
  echo "Preprocess the input T1 image and write the results to the output"
  echo "directory specified by 'fname' and 'outdir', respectively."
  echo ""
  echo "Options:"
  echo "  --bet-method  bet|optiBET  brain extraction method"
  echo "  --bet-params  <string>     pass-through params for bet"
  echo ""
  echo "External dependencies:"
  echo "  FSL      (https://fsl.fmrib.ox.ac.uk/fsl/fslwiki/FSL)"
  echo "  optiBET  (https://montilab.psych.ucla.edu/fmri-wiki/optibet)"
}

get_opt() {
  arg=`echo $1 | sed 's/=.*//'`
  echo $arg
}

fname() {
  fname=`basename $1`
  fname_stripped=${fname/.*/}
  echo $fname_stripped
}

[ "$#" -lt 2 ] && ( usage && exit 1 )

anat_in=`dirname $1`/`fname $1`
outdir=`fsl_abspath $2`
shift 2

# --- parameters / options
overwrite=0
bet_method="bet"
bet_params="-f 0.5"

while [ $# -ge 1 ] ; do
  name=`get_opt "$1"`
  shift
  value=`get_opt "$1"`
  echo "${name}: ${value}"

  case "${name}" in
    --bet-method)
      case "${value}" in
        bet|optiBET)
          bet_method="${value}"
          ;;
        *)
          echo "ERROR: Unexpected parameter value for --bet-method: ${value}"
          exit 1
          ;;
      esac
      ;;
    --bet-params)
      bet_params="${value}"
      ;;
    --overwrite)
      overwrite="${value}"
      ;;
    *)
      echo "unknown parameter identifier found: ${name}"
      usage
      exit 1
      ;;
 esac
 shift
done
echo ""

# --- input data
anat=${outdir}/`fname ${anat_in}`
echo "anat_in:       ${anat_in}"
echo "anat:          ${anat}"

# --- output directory
echo "outdir:        ${outdir}"

# --- brain extraction
echo "bet-method:    ${bet_method}"
echo "bet-params:    ${bet_params}"

# --- flirt options
flirt_in=${anat}_reo_bet_bfc              # reoriented, brain-extracted,
                                          # bias field corrected T1
flirt_ref=${FSLDIR}/data/standard/MNI152_T1_1mm_brain
flirt_omat=${outdir}/anat-to-mni_affine.mat
flirt_dof=12                              # degrees of freedom
flirt_interp=spline                       # interpolation method
echo "flirt-in:      ${flirt_in}"
echo "flirt-ref:     ${flirt_ref}"
echo "flirt-omat:    ${flirt_omat}"

# --- fnirt options
fnirt_in=${anat}_reo_bfc                  # reoriented, bias field corrected T1
fnirt_aff=${flirt_omat}                   # affine transform
fnirt_fout=${outdir}/anat-to-mni_field    # field
fnirt_jout=${outdir}/anat-to-mni_jacobian # Jacobian of the field
fnirt_refout=${outdir}/anat-to-mni_refout # intensity-modulated --ref
fnirt_iout=${fnirt_in}_mni                # output image
fnirt_intout=${outdir}/anat-to-mni_intout
fnirt_cout=${outdir}/anat-to-mni_warp     # field coefficients
fnirt_config="T1_2_MNI152_2mm"
fnirt_logout=${outdir}/fnirt.log          # log file
echo "fnirt-fout:    ${fnirt_fout}"
echo "fnirt-jout:    ${fnirt_jout}"
echo "fnirt-refout:  ${fnirt_refout}"
echo "fnirt-iout:    ${fnirt_iout}"
echo "fnirt-intout:  ${fnirt_intout}"
echo "fnirt-cout:    ${fnirt_cout}"
echo "fnirt-logout:  ${fnirt_logout}"
echo "fnirt-config:  ${fnirt_config}"
echo ""

# --- create output directory
printf "Creating output directory ...\n"
if [ ! -d ${outdir} ]; then
  mkdir -p ${outdir}
  printf "[done]\n\n"
else
  printf "[skipped] (output directory exists)\n\n"
fi

# --- reorient2std
printf "Runnung fslreorient2std ...\n"
if [ ! -f ${anat}_reo.nii.gz ] || [ $overwrite == 1 ]; then
  set -x
  fslreorient2std ${anat_in} ${anat}_reo
  set +x
  printf "[done]\n\n"
else
  printf "[skipped] (output exists)\n\n"
fi

# --- brain extraction
printf "Running bet ...\n"
set -x
if [ ! -f ${anat}_reo_bet.nii.gz ] || [ $overwrite == 1 ]; then
  if   [ "$bet_method" == "bet" ] ; then
    echo "bet ${anat}_reo ${anat}_reo_bet ${bet_params}"
    bet ${anat}_reo ${anat}_reo_bet ${bet_params}
  elif [ "$bet_method" == "optiBET" ] ; then
    echo "optiBET.sh -i ${anat}_reo ${bet_params}"
    optiBET.sh -i ${anat}_reo ${bet_params}
    rm ${anat}_reo_optiBET_brain_mask.nii.gz
    mv ${anat}_reo_optiBET_brain.nii.gz ${anat}_reo_bet.nii.gz
  fi
  printf "[done]\n\n"
else
  printf "[skipped] (output exists)\n\n"
fi
set +x

# --- fast segmentation (bias field correction)
printf "Running fast ...\n"
if [ ! -f ${anat}_reo_bet_bfc.nii.gz ] || [ $overwrite == 1 ]; then
  set -x
  fast -b -B ${anat}_reo_bet
  fslmaths ${anat}_reo_bet -div ${anat}_reo_bet_bias ${anat}_reo_bet_bfc
  fslmaths ${anat}_reo     -div ${anat}_reo_bet_bias ${anat}_reo_bfc
  set +x
  printf "[done]\n\n"
else
  printf "[skipped] (output exists)\n\n"
fi

# --- flirt 2 mni
printf "Running flirt: anat -> mni ...\n"
if [ ! -f ${flirt_omat} ] || [ $overwrite == 1 ]; then
  set -x
  flirt \
    -interp ${flirt_interp} \
    -dof ${flirt_dof} \
    -ref ${flirt_ref} \
    -in ${flirt_in} \
    -omat ${flirt_omat}
  set +x
  printf "[done]\n\n"
else
  printf "[skipped] (output exists)\n\n"
fi

# --- fnirt 2 mni
printf "Running fnirt: anat -> mni ...\n"
if [ ! -f ${fnirt_cout}.nii.gz ] || [ $overwrite == 1 ]; then
  set -x
  fnirt \
    --in=${fnirt_in} \
    --aff=${fnirt_aff} \
    --fout=${fnirt_fout} \
    --jout=${fnirt_jout} \
    --refout=${fnirt_refout} \
    --iout=${fnirt_iout} \
    --intout=${fnirt_intout} \
    --cout=${fnirt_cout} \
    --config=${fnirt_config} \
    --logout=${fnirt_logout}
  set +x
  printf "[done]\n\n"
else
  printf "[skipped] (output exists)\n\n"
fi

exit 0
