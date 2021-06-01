#!/bin/bash
#set -xv

FORCE=0
DRYRUN=0

for i in "$@"
do
case $i in
	-d|--dry-run)
	DRYRUN=1
	shift
	;;
	-f|--force)
	FORCE=1
	;;
	*)
	;;
esac
done


#get list of files to purge from cache

for f in $(find /var/www/html/wp-content/uploads/ -type f \( -iname \*.jpg -o -iname \*.png \) \
   -not \( -path */fly-images/* -prune \) \
   -not \( -path */csprite/* -prune \) \
   -printf "%P\n" );
do
	#case png
	if [[ $f == *".png" ]]; then
		ARGUMENTS=""
		PASSNOCHANGE=0
		if [ "${FORCE}" -eq 1 ]; then
			ARGUMENTS+=" -force"
			PASSNOCHANGE=1
		fi
		if [ "${DRYRUN}" -eq 1 ]; then
			ARGUMENTS+=" -simulate"
		fi

		optipng ${ARGUMENTS} -preserve -strip all "/var/www/html/wp-content/uploads/${f}" 2>&1| grep -q 'decrease)'

		if [ $? -eq 0 ] || [ "${PASSNOCHANGE}" -eq 1 ]; then
			purge+=(${f})
			echo Optimzed: $f
		else
			echo Skipped: $f
		fi
	fi

	#case jpg
	if [[ $f == *".jpg" ]]; then
		ARGUMENTS=""
		if [ "${FORCE}" -eq 1 ]; then
			ARGUMENTS+=" --force"
		fi
		if [ "${DRYRUN}" -eq 1 ]; then
			ARGUMENTS+=" -n"
		fi

		jpegoptim ${ARGUMENTS} -s -p --all-progressive "/var/www/html/wp-content/uploads/${f}" | grep -q 'optimized'

		if [ $? -eq 0 ]; then
			purge+=(${f})
			echo Optimzed: $f
		else
			echo Skipped: $f
		fi
	fi
done


#index count
echo Total files found: "${#purge[@]}"


#upload to s3 cdn spaces
ARGUMENTS=""
if [ "${DRYRUN}" -eq 1 ]; then
	ARGUMENTS+="--dry-run"
fi
for f in "${purge[@]}"; do
	s3cmd put /var/www/html/wp-content/uploads/$f s3://<<BUCKET_NAME>>/$f ${ARGUMENTS} --acl-public
done


#group per chunk to avoid timeout on api
g=20
for((i=0; i < ${#purge[@]}; i+=g))
do
	part=( "${purge[@]:i:g}" )
	#echo "Elements in this group: ${part[*]}"

	#json purgelist
	purgelist=`printf '%s\n' "${part[@]}" | jq -R . | jq -s '{"files":.}' -r`

	echo $purgelist | jq

	#purge cdn api
	if [ "${DRYRUN}" -eq 0 ]; then
		curl -X DELETE -H "Authorization: Bearer <<YOUR_DO_TOKEN_HERE>>" \
			"https://api.digitalocean.com/v2/cdn/endpoints/<<END_POINT_ID_HERE>>/cache" \
			-s -o /dev/null -w "%{http_code}" \
			-d "$purgelist"
	fi

done

#remove files older then one day locally
for f in $(find /var/www/html/wp-content/uploads/ -type f -mmin +$((60*24*1)) \( -iname \*.jpg -o -iname \*.png \) -printf "%P\n" );
do
	if [ "${DRYRUN}" -eq 1 ]; then
		echo Skipped remove: $f
	else
		rm /var/www/html/wp-content/uploads/$f
		echo Removed: $f
	fi
done

