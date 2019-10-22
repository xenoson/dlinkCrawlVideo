#!/bin/bash
#set -x 

###Script for dlink wifi camera to download files from internal SD card (probably very depended on one particular software version of the cam)
###Latest very talkative version with handling of interrupted transfers

username="admin"
password="password"
cred="$username:$password"

silent="-s"
IP="http://192.168.1.160/"
CURLCMD="curl $silent -u $cred $header"

#enpty root path "/" to start is right for crawling all directories
PATHSTR="/video"
PATHSTR="/video/20141006"
PAGE="1"
SKIP_JPEG="1"
SKIP_LOG="1"

LISTCGI="cgi-bin/sdlist.cgi?path="
LISTCGIPAGE="&page="

DOWNLOADCGI="cgi-bin/sddownload.cgi?file="
DOWNLOADOPTS="-R -O -C -"


#uncomment to output list of file urls with download command, not run the actual download (makes sense to tun off verbose then)
#URLLIST="echo"

#explain what's going on
verbose="1"
#debug will output all html/javascript content
#debug="1"
[ $debug ] && verbose="1"


oldIFS=$IFS


#This Array defines regexp strings and here in the second column a Variable name to fill with extracted data
contentExtractionAnchorArray=( \
"^var g_folderslistStr = GV("		"csvdirlist"	#content extraction for directory processing	\
"^var g_filelistStr = GV(" 		"csvfilelist"	#content extraction for file processing	\
"^var g_totalpage = parseInt(GV"	"totalpage" 	#content extraction for page processing	\
"^var g_thispage = parseInt(GV" 	"thispage"	\
)

#This rewrites the above array into a hash array to conveniently find the regexp string by variable name
declare -A extractionAnchorByName #declaration as associative array is essential
if (( ${#contentExtractionAnchorArray[*]} % 2 == 0 ))
then
  for (( i = 0; i < ${#contentExtractionAnchorArray[*]}; i+=2 ))
  do
  extractionAnchorByName["${contentExtractionAnchorArray[i+1]}"]="${contentExtractionAnchorArray[i]}"
done
else
  echo "check definition of contentExtractionAnchorArray" && exit 1
fi


#don"t try cgi-bin/sdlist.cgi?path=/\&page=1 will crash cgi

#cgi-bin/sdlist.cgi?path=\&page=1
#cgi-bin/sdlist.cgi?path=/Video\&page=1
#cgi-bin/sdlist.cgi?path=/Video/20130606\&page=1
#cgi-bin/sdlist.cgi?path=/Video/20130606\03&page=1
#cgi-bin/sddownload.cgi?file=/video/20130606/03/event_video20130606_012032_0843.avi

#192.168.1.99/cgi-bin/sdlist.cgi?path=/video/20130606/03\&page=1


fetch()
{
  local csvlist="$1"
  local fetchcmd="$2"

  [ $verbose ] && echo "Fetch called with csvlist \"$csvlist\" and fetchcmd \"$fetchcmd\" beginning to process entries:"

  local IFS="," #this is row seperator
  local rowstr
  local entry
  local entrydatestr
  for rowstr in $csvlist
  do
    entry=$(echo $rowstr | cut -d\; -f1) #this is column seperator
    entrydatestr=$(echo $rowstr | cut -d\; -f8)
    [ $verbose ] && echo "fetch processing the next entry:"
    if [[ "$entry" != "" ]]
    then
      [ $verbose ] && echo "found entry: \"$entry\""
      
      if [[ "$SKIP_JPEG" == "1" && "$entry" == *.jpg ]]
      then
        [ $verbose ] && echo "skipping jpeg: \"$entry\""
        continue
      fi

      if [[ "$SKIP_LOG" == "1" && "$entry" == *.log ]]
      then
        [ $verbose ] && echo "skipping log: \"$entry\""
        continue
      fi
      
      if [ -e "$entry" ]
      then
        echo "file exists: \"$entry\"" #A valid reason for curl to return >0
        local filedatestr=$(stat -c%Y $entry)
        if [[ "$entrydatestr" != "$filedatestr" ]]
        then
          [ $verbose ] && echo "existing file \"$entry\" has different modification time \"$filedatestr\" than entry \"$entrydatestr\", assume interrupted transfer, deleting file"
          rm -f -- $entry
          [ $verbose ] && echo "and retrying transfer." 
        else
          [ $verbose ] && echo "existing file has same modification time \"$filedatestr\" as entry \"$entrydatestr\", skiping file."
          continue
        fi
      fi

      if ! IFS=$oldIFS eval "$fetchcmd"
      then
        #this is a problem resume does not work with existing files and curl gives exit status > 0
        #an incomplete file will not be resumed but will get the correct modification time
        #so we have to check all times before so we can
        #delete it in case of iterruption
        if [ ! -e "$entry" ]
        then
          echo "ERROR: fetch called fetchcmd: \"$fetchcmd\""
          echo "       probably crawl returned 1. because fetch called crawl with nonesense entry. This should not happen."
          echo "       It would be really strange if fetchcmd was curl because there is no file named entry: \"$entry\""
          return 1
        else
          echo "ERROR: curl gave error and file exists: \"$entry\"" #A valid reason for curl to return >0
          echo "       Transfer of file \"$entry\" failed, giving up on it and exit. This should not happen. Maybe disk full or existing file was not deleted."
          return 1
        fi
      else
        [ $verbose ] && echo "Transfer of file \"$entry\" succeeded."
      fi
      sleep 0.1
    else
      echo "ERROR: fetch extracted empty entry. Something is really wrong."
      return 1
    fi
  done
  [ $verbose ] && echo "so fetch called with csvlist \"$csvlist\" and fetchcmd \"$fetchcmd\" sucessfully processed all entries,"
  IFS=$oldIFS
  return 0
}

crawl()
{
  local pathstr="$1"
  local page="$2"
  [ $verbose ] && echo "This is crawl called with pathstr: \"$pathstr\" and page: \"$page\""

  directoryProcessing()
  {
  [ $verbose ] && echo "Processing directories:"
  if [[ "$csvdirlist" != "" ]]
  then
    if ! fetch "$csvdirlist" "crawl ${pathstr}/\$entry $PAGE"
    then
      echo "ERROR: crawl directoryProcessing called fetch to call crawl. Fetch returned error." 
      echo "       This can happen if called crawl caused the error. Otherwise crawl called fetch with nonesense csvdirlist."
      return 1
    fi
  [ $verbose ] && echo "so fetch done on directories in path: \"$pathstr\"."
  else
    [ $verbose ] && echo "csvdirlist was empty, so there are no more directories here in path: \"$pathstr\" to descent into, threrefore directory processing is sucessfully done."
    emptycsvdirlist="1"
  fi
  }

  fileProcessing()
  {
  [ $verbose ] && echo "Processing files:"
  if [[ "$csvfilelist" != "" ]]
  then
    if ! fetch "$csvfilelist" "$URLLIST $CURLCMD $DOWNLOADOPTS ${IP}$DOWNLOADCGI$pathstr/\$entry"
    then
    echo "ERROR: crawl fileProcessing called fetch to call curl and fetch returned error. Probably some nonesense in csvfilelist made curl fail."
    return 1
    fi
    [ $verbose ] && echo "so file processing succesfully done in path: \"$pathstr\"."
  else
    [ $verbose ] && echo "but csvfilelist was empty, so no files here in path: \"$pathstr\"."
    emptycsvfilelist="1"
  fi
  }


  pageProcessing()
  {
  if [[ "$totalpage" != "" ]]
  then
    if [[ "$totalpage" == "0" ]]
    then
      [ $verbose ] && echo "totalpage is: \"$totalpage\". This is fine for empty directory and cgi error handling for non existant path requests. Skipping."
      return 0
    fi

    [ $verbose ] && echo "We are still on page \"$page\", found total of \"$totalpage\" pages, "
    if [[ "$page" == "1" && "$totalpage" != "1" ]]
    then
      local multipage
      for multipage in $(seq 2 "$totalpage") #no quotes intentionally, quotes arount here will put the 2 3 in one line
      do
	[ $verbose ] && echo "processing page \"$multipage\""
	if ! crawl "$pathstr" "$multipage"
	then
	  echo "ERROR: crawl called crawl with nonesense pathstr and multipage."
	  return 1
	fi
	[ $verbose ] && echo "crawl to page \"$multipage\" done."
      done
    else
      [ $verbose ] && echo "but with a total of $totalpage page on page $page there are no additional pages to process,"
    fi
  else
    [ $verbose ] && echo "totalpage is empty."
    emptytotalpage="1"
  fi
  }

  contentExtraction()
  {
  local url="${LISTCGI}${pathstr}${LISTCGIPAGE}${page}" 
  [ $verbose ] && echo "trying cgi url: \"${CURLCMD} "${IP}${url}"\""
  local changedContent=$(${CURLCMD} "${IP}${url}" | grep ChangeContent | cut -d\' -f2)
  [ $debug ] && echo "extracted changedContent: \"$changedContent\""
  sleep 0.3
  [ $verbose ] && echo "trying changedContent redirection: \"${CURLCMD} "${IP}${changedContent}"\""
  realcontent=$(${CURLCMD} "${IP}${changedContent}")
  [ $debug ] && echo "found realcontent: \"$realcontent\""
  unset changedContent
  unset url
  }

  realcontentExtractionWrapper() 
  {
  [ $debug ] && echo "using index: \"$1\" for extractionAnchorByName. Anchor is: \"${extractionAnchorByName[$1]}\""
  local value=$(echo "$realcontent" | grep "${extractionAnchorByName[$1]}" | cut -d\" -f2)
  eval $1="\${value}"
  unset value
  [ $debug ] && echo "extracted $1: \"$(eval echo \$$1)\""
  }

  #start of crawl
  local realcontent
  contentExtraction


  local csvdirlist
  realcontentExtractionWrapper csvdirlist

  local emptycsvdirlist="0"
  if ! directoryProcessing
  then
    return 1
  fi

  local csvfilelist
  realcontentExtractionWrapper csvfilelist

  local emptycsvfilelist="0"
  if ! fileProcessing
  then
    return 1
  fi

  [ $verbose ] && [ $emptycsvdirlist == "1" ] && [ $emptycsvfilelist == "1" ] && echo "Both csvdirlist and csvfilelist are empty."

  [ $verbose ] && echo "This is still crawl called with pathstr: \"$pathstr\" and page: \"$page\", now looking for multiple pages."

  local totalpage
  realcontentExtractionWrapper totalpage

  local thispage
  realcontentExtractionWrapper thispage

  local emptytotalpage="0"
  if ! pageProcessing
  then
    return 1
  fi

  if [[ $emptycsvdirlist == "1" ]] && [[ $emptycsvfilelist == "1" ]] && [[ $emptytotalpage == "1" ]]
  then
    echo "All regexps returned empty strings. Unable to extract useful information from content. Probably wrong request." && return 1
  fi

  [ $verbose ] && echo "so crawl called with pathstr: \"$pathstr\" and page: \"$page\" is sucessfully done and the calling fetch will proceed processing."
  
  return 0
}


#init
tmp=$($CURLCMD ${IP}setup.htm)
unset tmp
#echo $tmp

[ $verbose ] && echo "This is $0"
if ! crawl "$PATHSTR" "$PAGE"
then
  echo "ERROR: Either an error before or main called crawl with hardcoded nonesense PATHSTR and PAGE"
fi
[ $verbose ] && echo "main crawl done."

exit 0


