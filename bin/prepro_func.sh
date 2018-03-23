#!/bin/bash
#-----------------------------------------------------------------------------
# Preprocessing of functional (EPI) images
#
# (1) Despiking              (optional)    (3dDespike)
#     Despiking can be done before or after slice time correction.
#
# (2) Slice time correction  (optional)    (slicetimer)
#
# (3) Motion correction                    (mcflirt)
#     Motion correction is carried using mcflirt to realign the images to
#     their mean.
#     fsl_motion_outliers is used to compute refrms and dvars.
#
# (4) Registration to T1                   (epi_reg)
#     Performs simultaneous registration and EPI distortion correction, if a
#     fieldmap, the phase encoding direction, and the effective echo spacing
#     are provided.
#
# (5) Registration to standard space
#     Registration to standard space is achieved by combines the result of
#     EPI-to-T1 registration with the warp specified using "--anat2ref".
#
# The spatial transformations from steps 3-5 are combined into a single
# warp to avoid unnecessary resampling.
#
# External dependencies:
#   FSL   (https://fsl.fmrib.ox.ac.uk/fsl/fslwiki/FSL)
#   AFNI  (https://afni.nimh.nih.gov)
#
# Author: Kristian Loewe
#-----------------------------------------------------------------------------
set -e

# --- functions
usage() {
  echo "Usage: `basename $0` fname outdir [required] [options]"
  echo ""
  echo "Preprocess the input fMRI data and write the results to the output"
  echo "directory specified by 'fname' and 'outdir', respectively."
  echo ""
  echo "Required:"
  echo "  fname                <4d>"
  echo "  outdir               <output directory>"
  echo "  --anat               <3d>"
  echo "  --anatbet            <3d>"
  echo "  --ref                <3d>"
  echo "  --anat2ref           <warp>"
  echo "  --wmseg              <3d>"
  echo "  --TR                 <float>"
  echo ""
  echo "Options:"
  echo "  --despike            0/1             use despiking (default: 0)"
  echo "  --despike-after-stc  0/1             despiking after stc (d.: 0)"
  echo "  --stc                0/1             use slice time correction"
  echo "  --stc-order          <file>          sliceorder file"
  echo "  --mc-stages          3/4             # search levels (default: 3)"
  echo "  --fmap               <3d>            fieldmap"
  echo "  --mag                <3d>            fieldmap magnitude image"
  echo "  --magbet             <3d>            f.m.i. (brain-extracted)"
  echo "  --echosp             <float>         eff. echospacing in seconds"
  echo "  --pedir              x/y/z/-x/-y/-z  phase encoding direction"
  echo ""
  echo "External dependencies:"
  echo "  FSL   (https://fsl.fmrib.ox.ac.uk/fsl/fslwiki/FSL)"
  echo "  AFNI  (https://afni.nimh.nih.gov)"
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

despike() {
  export OMP_NUM_THREADS=1
  set -x
  3dDespike -prefix ${2} ${1}.* > ${2}_3dDespike.log 2>&1
  set +x
  unset OMP_NUM_THREADS
  set -x
  3dAFNItoNIFTI -pure -prefix ${2} ${2}*.HEAD > ${2}_3dAFNItoNIFTI.log 2>&1
  rm ${2}*.BRIK
  rm ${2}*.HEAD
  gzip ${2}.nii
  set +x
}

# --- check the number of input arguments
[ "$#" -lt 14 ] && ( usage && exit 1 )

# --- check external dependencies
if ! [ -x "$(command -v afni)" ]; then
  echo "Error: Could not find AFNI."
  exit 1
fi
if ! [ -x "$(command -v fsl)" ]; then
  echo "Error: Could not find FSL."
  exit 1
fi

# --- required arguments
func=`dirname $1`/`fname $1`   # strip extension
outdir=`fsl_abspath $2`
shift 2

# --- required/options
overwrite=0

# required
anat=""
anat_bet=""
ref=""
anat2ref_warp=""
wmseg=""
TR=""

# options
do_despike=false               # despiking
despike_after_stc=false
do_stc=false                   # slice time correction
sliceorder=""
mc_stages=3                    # motion correction
fmap=""                        # field map (epi_reg)
mag=""
mag_bet=""
echosp=""
pedir=""

while [ $# -ge 1 ] ; do
 name=`get_opt $1`
 shift
 value=`get_opt $1`
 #echo "${name}: ${value}"

 case "${name}"
    in
    --anat)
      anat=`fsl_abspath ${value}`
      ;;
    --anatbet)
      anat_bet=`fsl_abspath ${value}`
      ;;
    --ref)
      ref=`fsl_abspath ${value}`
      ;;
    --anat2ref)
      anat2ref_warp=`fsl_abspath ${value}`
      ;;
    --wmseg)
      wmseg=`fsl_abspath ${value}`
      ;;
    --TR)
      TR="${value}"
      ;;
    --despike)
      if (( $value )) ; then
        do_despike=true
      else
        do_despike=false
      fi
      ;;
    --despike-after-stc)
      if (( $value )) ; then
        despike_after_stc=true
      else
        despike_after_stc=false
      fi
      ;;
    --stc)
      if (( $value )) ; then
        do_stc=true
      else
        do_stc=false
      fi
      ;;
    --stc-order)
      sliceorder=`fsl_abspath ${value}`
      ;;
    --mc-stages)
      mc_stages="${value}"
      ;;
    --fmap)
      fmap=`fsl_abspath ${value}`
      ;;
    --mag)
      mag=`fsl_abspath ${value}`
      ;;
    --magbet)
      mag_bet=`fsl_abspath ${value}`
      ;;
    --echosp)
      echosp="${value}"
      ;;
    --pedir)
      pedir="${value}"
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

# --- create output directory
printf "Creating output directory ...\n"
if [ ! -d ${outdir} ]; then
  mkdir -p ${outdir}
  printf "[done]\n\n"
else
  printf "[skipped] (output directory exists)\n\n"
fi

# --- init variables
func_in=${func}
func_out=${func_in}
func_in_onestep=${func_in}
func_name=`fname ${func}`

# --- despike (if to be done first)
if [ $do_despike = true ] && [ $despike_after_stc = false ]; then
  printf "Despiking ...\n"
  func_in=${func_out}
  func_out=${outdir}/`fname ${func_in}`_despike
  func_in_onestep=${func_out}
  if [ ! -f ${func_out}.nii.gz ] || [ $overwrite == 1 ]; then
    despike ${func_in} ${func_out}
    printf "[done]\n\n"
  else
    printf "[skipped] (output exists)\n\n"
  fi
fi

# --- slice time correction 
if [ $do_stc = true ]; then
  printf "Slice Time Correction ...\n"
  func_in=${func_out}
  func_out=${outdir}/`fname ${func_in}`_stc
  func_in_onestep=${func_out}
  if [ ! -f ${func_out}.nii.gz ] || [ $overwrite == 1 ]; then
    set -x
    slicetimer \
      -i ${func_in} \
      -o ${func_out} \
      -r ${TR} \
      --ocustom=${sliceorder} \
      -v > ${func_out}_slicetimer.log 2>&1
    set +x
    printf "[done]\n\n"
  else
    printf "[skipped] (output exists)\n\n"
  fi
fi

# --- despike (if to be done after stc)
if [ $do_despike = true ] && [ $despike_after_stc = true ]; then
  printf "Despiking ...\n"
  func_in=${func_out}
  func_out=${outdir}/`fname ${func_in}`_despiked
  func_in_onestep=${func_out}
  if [ ! -f ${func_out}.nii.gz ] || [ $overwrite == 1 ]; then
    despike ${func_in} ${func_out}
    printf "[done]\n\n"
  else
    printf "[skipped] (output exists)\n\n"
  fi
fi

# --- motion correction
printf "Motion Correction ...\n"
func_in=${func_out}
func_out=${func_in}_mc
if [ ! -f ${func_out}.nii.gz ] || [ $overwrite == 1 ]; then
  set -x
  mcflirt \
    -in ${func_in} \
    -out ${func_out} \
    -meanvol \
    -stages ${mc_stages}  \
    -stats -mats -plots -report > ${func_out}_mcflirt.log 2>&1
  set +x
  printf "[done]\n\n"
else
  printf "[skipped] (output exists)\n\n"
fi

# --- motion outliers
printf "FSL Motion Outliers ...\n"
for metric in refrms dvars; do
  printf "metric: ${metric} ...\n"
  if [ ! -f ${func_out}_fmo_${metric}.cf ] || [ $overwrite == 1 ]; then
    set -x
    fsl_motion_outliers \
      -i ${func_out}.nii.gz \
      -o ${func_out}_fmo_${metric}.cf \
      -s ${func_out}_fmo_${metric}.txt \
      -p ${func_out}_fmo_${metric}.png \
      --${metric} \
      --nomoco \
      -v > ${func_out}_fmo_${metric}.log 2>&1
    set +x
    printf "[done]\n"
  else
    printf "[skipped] (output exists)\n"
  fi
done
printf "\n"

# --- run epi_reg
printf "Epi_reg ...\n"
func_in=${func_out}
if [ ! -f ${outdir}/${func_name}-to-anat.mat ] || [ $overwrite == 1 ]; then
  if [ -n "${fmap}" ]; then
    set -x
    epi_reg \
      --epi=${func_in}_meanvol \
      --t1=${anat} \
      --t1brain=${anat_bet} \
      --wmseg=${wmseg} \
      --fmap=${fmap} \
      --fmapmag=${mag} \
      --fmapmagbrain=${mag_bet} \
      --echospacing=${echosp} \
      --pedir=${pedir} \
      --out=${outdir}/${func_name}-to-anat \
      -v > ${outdir}/${func_name}-to-anat_epi_reg.log 2>&1
    set +x
  else
    set -x
    epi_reg \
      --epi=${func_in}_meanvol \
      --t1=${anat} \
      --t1brain=${anat_bet} \
      --wmseg=${wmseg} \
      --out=${outdir}/${func_name}-to-anat \
      -v > ${outdir}/${func_name}-to-anat_epi_reg.log 2>&1
    set +x
  fi
  printf "[done]\n\n"
else
  printf "[skipped] (output exists)\n\n"
fi

# --- combine warps
printf "Combining warps ...\n"
out=${outdir}/${func_name}-to-mni_combined-warp
if [ ! -f ${out}.nii.gz ] || [ $overwrite == 1 ]; then
  if [ -n "${fmap}" ]; then
    set -x
    convertwarp \
      --ref=${ref} \
      --warp1=${outdir}/${func_name}-to-anat_warp \
      --warp2=${anat2ref_warp} \
      --out=${out} \
      -v > ${out}_convertwarp.log 2>&1
    set +x
  else
    set -x
    convertwarp \
      --ref=${ref} \
      --premat=${outdir}/${func_name}-to-anat.mat \
      --warp1=${anat2ref_warp} \
      --out=${out} \
      -v > ${out}_convertwarp.log 2>&1
    set +x
  fi
  printf "[done]\n\n"
else
  printf "[skipped] (output exists)\n\n"
fi

# --- one-step resampling
printf "One-step resampling ...\n"
func_out=${func_in_onestep}_mni
if [ ! -f ${func_out}.nii.gz ] || [ $overwrite == 1 ]; then
  set -x
  mkdir -p ${outdir}/${func_name}_prevols
  mkdir -p ${outdir}/${func_name}_postvols
  set -x

  # split 4D functional into individual volumes ...
  prefix=vol
  set -x
  fslsplit ${func_in_onestep} ${outdir}/${func_name}_prevols/${prefix} -t
  set +x

  mc_mat_dir="${func_in_onestep}_mc.mat"
  mc_mat_prefix="MAT_"
  T=`fslval ${func_in_onestep} dim4` # the number of time points
  T=`echo $T | tr -d [:blank:]`      # trim the trailing white space char
  n_chars=`echo $((${#T}>4?${#T}:4))`
  i=0
  while [ $i -lt $T ] ; do
    echo $i
    no=`printf "%0${n_chars}d" $i`
    echo $no

    # combine motion correction transformation with "combined_warp"
    set -x
    convertwarp --relout --rel \
      --ref=${ref} \
      --premat=${mc_mat_dir}/${mc_mat_prefix}${no} \
      --warp1=${outdir}/${func_name}-to-mni_combined-warp \
      --out=${mc_mat_dir}/${mc_mat_prefix}${no}_warp
    set +x

    # apply the resulting warp
    set -x
    applywarp \
      --ref=${ref} \
      --in=${outdir}/${func_name}_prevols/${prefix}${no} \
      --warp=${mc_mat_dir}/${mc_mat_prefix}${no}_warp \
      --out=${outdir}/${func_name}_postvols/${prefix}${no} \
      --interp=spline
    set +x

    i=$(($i+1))
  done

  # merge warped volumes
  set -x
  fslmerge -tr ${func_out} \
    ${outdir}/${func_name}_postvols/${prefix}*.nii* ${TR}
  set +x

  printf "[done]\n\n"
else
  printf "[skipped] (output exists)\n\n"
fi

exit 0
