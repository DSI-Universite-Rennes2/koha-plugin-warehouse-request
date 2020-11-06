#!/bin/bash
DIRNAME=$(dirname $0);
cd $DIRNAME;

source ./package.sh;
TODAY=$(date +%Y-%m-%d);
KPZFILENAME=$PROJECTNAME-v$VERSION.kpz;
FILEPATHFULLDIST=dist/$FILEPATH/$FILENAME;

mkdir dist ;
cp -r Koha dist/. ;
perl -pi -e "s/{VERSION}/$VERSION/g" $FILEPATHFULLDIST ;
perl -pi -e "s/{UPDATE_DATE}/$TODAY/g" $FILEPATHFULLDIST ;
cd dist ;
zip -r ../kpz/$KPZFILENAME ./Koha -x "*.DS_Store";
cd .. ;
rm -rf dist ;
