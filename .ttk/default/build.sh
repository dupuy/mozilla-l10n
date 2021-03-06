#!/bin/bash -e
#
# Copyright 2009 João Miguel Neves <joao.neves@intraneia.com>
# Copyright 2008 Zuza Software Foundation
#
# This file is part of Translate.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, see <http://www.gnu.org/licenses/>.

##########################################################################
# NOTE: Documentation regarding (the use of) this script can be found at #
# http://translate.sourceforge.net/wiki/toolkit/mozilla_l10n_scripts     #
##########################################################################

source ttk.inc.sh

abs_start_time=$(date +%s)
start_time=$abs_start_time
opt_vc=""
opt_build_xpi=""
opt_tarball=""
opt_compare_locales="yes"
opt_copyfiles="yes"
opt_time=""

hgverbosity="--quiet" # --verbose to make it noisy
gitverbosity="--quiet" # --verbose to make it noisy
pomigrate2verbosity="--quiet"
get_moz_enUS_verbosity=""
easy_install_verbosity="--quiet"
tar_verbosity=""


for option in $*
do
	if [ "${option##-*}" != "$option" ]; then
		case $option in
			--xpi)
				opt_build_xpi="yes"
			;;
			--tarball)
				opt_tarball="yes"
			;;
			--vc)
				opt_vc="yes"
			;;
			--no-compare-locales)
				opt_compare_locales=""
			;;
			--no-copyfiles)
				opt_copyfiles=""
			;;
			--verbose)
				opt_verbose="yes"
				hgverbosity="--verbose"
				gitverbosity=""
				progress=bar
				pomigrate2verbosity=""
				get_moz_enUS_verbosity="-v"
				easy_install_verbosity="--verbose"
				tar_verbosity="v"
			;;
			--time)
				opt_time="yes"
			;;
			*) 
			echo "Unkown option: $option"
			exit
			;;
		esac
		shift
	else
		break
	fi
done

if [ $# -eq 0 ]; then
	HG_LANGS=$(all_langs)
elif [ $# -eq 1 -a -z "${1//[0-9]/}" ]; then
	HG_LANGS=$(all_langs $1)
else
	HG_LANGS=$*
fi
log_info "Processing languages '$HG_LANGS'"

for lang in $HG_LANGS
do
	if [ "$lang" == "templates" ]; then
		opt_vc="yes"
		break
	fi
done

# Check requirements:
require git hg moz2po po2moz get_moz_enUS.py
[ opt_compare_locales ] && require compare-locales
[ opt_build_xpi ] && require buildxpi.py
[ opt_tarball ] && require tar


# FIXME lets make this the execution directory
BASE_DIR=$(pwd)
BUILD_DIR="${BASE_DIR}/build"
SOURCE_DIR="${BASE_DIR}/source"
MOZ_DIR="mozilla-aurora"
# FIXME rename this
MOZCENTRAL_DIR="${SOURCE_DIR}/${MOZ_DIR}"
L10N_DIR="${BUILD_DIR}/l10n"
PO_DIR="${BASE_DIR}"
L10N_ENUS="${PO_DIR}/templates-en-US"
POT_DIR="${PO_DIR}/templates"
LANGPACK_DIR="${BUILD_DIR}/xpi"
TARBALL_DIR="${BUILD_DIR}/tarball"

if [ $opt_vc ]; then
	verbose "${MOZ_DIR} - update/pull using Mercurial"
	if [ -d "${MOZCENTRAL_DIR}/.hg" ]; then
		cd ${MOZCENTRAL_DIR}
		hg pull $hgverbosity -u
		hg update $hgverbosity -C
	else
		hg clone $hgverbosity http://hg.mozilla.org/releases/${MOZ_DIR}/ ${MOZCENTRAL_DIR}
	fi
fi

if [ "$opt_vc" -o ! -d "${PO_DIR}" ]; then
	verbose "Translations - prepare the parent directory po/"
	for trans_repo in ${PO_DIR}
	do
		if [ -d $trans_repo ]; then
			(cd $trans_repo
			git stash $gitverbosity
			git pull $gitverbosity --rebase
			git checkout $gitverbosity
			git stash pop $gitverbosity || true)
		else
			git clone $gitverbosity git@github.com:translate/mozilla-l10n.git $trans_repo || git clone $gitverbosity git://github.com/translate/mozilla-l10n.git $trans_repo
		fi
	done
fi

verbose "Localisations - update Mercurial-managed languages in ${L10N_DIR}"
mkdir -p ${L10N_DIR}
cd ${L10N_DIR}
for lang in ${HG_LANGS}
do
	mozlang=$(get_language_upstream $lang)
	if [ $opt_vc ]; then
		verbose "Update ${L10N_DIR}/$mozlang"
		if [ -d ${mozlang} ]; then
			if [ -d ${mozlang}/.hg ]; then
			        (cd ${mozlang}
				hg revert $hgverbosity --no-backup --all -r default
				hg pull $hgverbosity -u
				hg update $hgverbosity -C)
			else
			        rm -rf ${mozlang}/* 
			fi
		else
		    hg clone $hgverbosity http://hg.mozilla.org/releases/l10n/${MOZ_DIR}/${mozlang} ${mozlang} || mkdir ${mozlang}
		fi
	fi
done

if [ $opt_vc ]; then
	[ -d ${POT_DIR} ] && rm -rf ${POT_DIR}/
	
	verbose "Extract the en-US source files from the repo into localisation structure"
	rm -rf ${L10N_ENUS} ${PO_DIR}/en-US
	get_moz_enUS.py $get_moz_enUS_verbosity -s ${MOZCENTRAL_DIR} -d ${PO_DIR} -p ${MOZ_PRODUCT}
	mv ${PO_DIR}/en-US ${L10N_ENUS}
	
	verbose "moz2po - Create POT files from en-US"
	(cd ${L10N_ENUS}
	moz2po --errorlevel=$errorlevel --progress=$progress -P --duplicates=msgctxt --exclude '.hg'  . ${POT_DIR}
	)
	if [ $USECPO -eq 0 ]; then
		(cd ${POT_DIR}
		clean_po ${PRODUCT_DIRS}
		)
	fi
	pot_dir=$(basename ${POT_DIR})
	# FIXME need to be selective based on product dirs
	revert_unchanged_po_git ${POT_DIR}/.. ${pot_dir}
fi

if [ $opt_vc ]; then
	verbose "Update ${PO_DIR} in case any changes are in version control"
	(cd ${PO_DIR};
	git stash $gitverbosity
	git pull $gitverbosity --rebase
	git checkout $gitverbosity
	git stash pop $gitverbosity || true)
fi

verbose "Translations - build Mozilla files in ${L10N_DIR}"
for lang in ${HG_LANGS}
do
	if [ "$lang" == "templates" ]; then
		continue
	fi
	log_info "Language: $lang"
	polang=$(get_language_pootle $lang)
	mozlang=$(get_language_upstream $lang)
	verbose "Migrate - update PO files to new POT files"
	tempdir=`mktemp -d tmp.XXXXXXXXXX`
	if [ -d ${PO_DIR}/${polang} ]; then
		cp -R ${PO_DIR}/${polang} ${tempdir}/${polang}
		(cd ${PO_DIR}/${polang}; rm $(find ${PRODUCT_DIRS} ${RETIRED_PRODUCT_DIR} -type f -name "*.po"))
	fi
	pomigrate2 --use-compendium --pot2po $pomigrate2verbosity ${tempdir}/${polang} ${PO_DIR}/${polang} ${POT_DIR}
	# FIXME we should revert stuff that wasn't part of this migration e.g. mobile
	rm -rf ${tempdir}

	(cd ${PO_DIR}
	if [ $USECPO -eq 0 ]; then
		(cd ${polang}
		clean_po ${PRODUCT_DIRS}
		)
	fi

	revert_unchanged_po_git ${PO_DIR} ${polang}
	vc_addremove_git ${PO_DIR} ${polang}

	verbose "Pre-po2moz hacks"
	mozlang_product_dirs=
	for dir in ${PRODUCT_DIRS}
	do
		mozlang_product_dirs="${mozlang_product_dirs} $mozlang/$dir"
	done
	for product_dir in ${mozlang_product_dirs}
	do
		[ -d ${L10N_DIR}/${product_dir} ] && find ${L10N_DIR}/${product_dir} \( -name '*.dtd' -o -name '*.properties' \) -exec rm -f {} \;
	done

	verbose "po2moz - Create Mozilla l10n layout from migrated PO files."
	for exclude in $RETIRED_PRODUCT_DIR
	do
		excludes=$(echo '$excludes --exclude="$exclude"')
	done
	echo $excludes
	po2moz --progress=$progress --errorlevel=$errorlevel --exclude=".git" --exclude=".hg" --exclude=".hgtags" --exclude="obsolete" --exclude="editor" --exclude="mail" --exclude="thunderbird" --exclude="chat" --exclude="*~" $excludes \
		-t ${L10N_ENUS} -i ${PO_DIR}/${polang} -o ${L10N_DIR}/${mozlang}

	if [ $opt_copyfiles ]; then
		# FIXME: work out how to break these apart so that mobile can build
		verbose "Copy files not handled by moz2po/po2moz"
		copyfileifmissing toolkit/chrome/mozapps/help/welcome.xhtml ${mozlang}
		copyfileifmissing toolkit/chrome/mozapps/help/help-toc.rdf ${mozlang}
		copyfile browser/firefox-l10n.js ${mozlang}
		copyfile browser/profile/chrome/userChrome-example.css ${mozlang}
		copyfile browser/profile/chrome/userContent-example.css ${mozlang}
		copyfileifmissing toolkit/chrome/global/intl.css ${mozlang}
		# This one needs special approval but we need it to pass and compile
		copyfileifmissing browser/searchplugins/list.txt ${mozlang}
		# Revert some files that need careful human review or authorisation
		if [ -d ${L10N_DIR}/${mozlang}/.hg ]; then
			(cd ${L10N_DIR}/${mozlang}
			hg revert $hgverbosity --no-backup browser/chrome/browser-region/region.properties browser/searchplugins/list.txt
			)
		fi
	fi

	## CREATE XPI LANGPACK
	if [ $opt_build_xpi ]; then
		mkdir -p ${LANGPACK_DIR}
		verbose "Language Pack - create an XPI"
		buildxpi.py -d -L ${L10N_DIR} -s ${MOZCENTRAL_DIR} -o ${LANGPACK_DIR} ${mozlang}
	fi

	# COMPARE LOCALES
	if [ $opt_compare_locales ]; then
		verbose "Compare-Locales - to find errors"
		if [ -f ${MOZCENTRAL_DIR}/${MOZ_PRODUCT}/locales/l10n.ini ]; then
			compare-locales ${MOZCENTRAL_DIR}/${MOZ_PRODUCT}/locales/l10n.ini ${L10N_DIR} $mozlang
		else
			echo "Can't run compare-locales without ${MOZCENTRAL_DIR} checkout"
		fi
	fi

	# Make a tarball
	if [ $opt_tarball ]; then
		log_info "Creating tarball of target format"
		mkdir -p ${TARBALL_DIR}
		# Name will be e.g.: af-21.0a2-20130213T1234-xxxxxxx.tar.bz2
		# There is no mobile/config/version.txt so keep it pointing to browser
		version=$(cat ${MOZCENTRAL_DIR}/browser/config/version.txt)
		build_date=$(date +%Y%m%dT%H%M)
		vc_hash=$(get_hash ${PO_DIR}/${polang})
		tarball_name=${mozlang}-$version-$build_date-$vc_hash.tar.bz2
		(cd ${L10N_DIR}
		tar c${tar_verbosity}jf ${TARBALL_DIR}/$tarball_name ${mozlang_product_dirs})
	fi
	)

done

# Cleanup rubbish we seem to leave behind
rm -rf ${L10N_DIR}/tmp*
abs_end_time=$(date +%s)
total_time=$(($abs_end_time - $abs_start_time))
verbose "Total time $(date --date="@$total_time" +%M:%S)"
