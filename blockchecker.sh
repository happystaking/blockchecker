#!/bin/bash

# Script arguments
cfg=$1
ago=${2:-'4h'}

if [ -z $cfg ]; then echo "Please pass the path to the configuation as the first argument."; exit; fi
if [ !-r $cfg ]; then echo "Error: '$cfg' not readable."; exit; fi

# Script variables
source $cfg
sshConn="-p $sshPort -i $sshIdFile"
pgConn="-h $PGHOST -U $PGUSER -d $PGDATABASE"
relays=$(psql $pgConn -t --csv -c 'select * from relay;')
counter=1

# Function definitions
function upsertBlock {
    epoch=$(echo "(((1591566291 + $1) / 86400) - (1506203091 / 86400) - 1) / 5" | bc)
    sql=$(echo "insert into block
            (slot, epoch, height, hash, forged_at, adopted_at, pooltool_ms)
        values
            ($1, $epoch, $2, '$3', '$4', '$5', $6)
        on conflict (slot) do update set
            height=$2, hash='$3', forged_at='$4', adopted_at='$5', pooltool_ms='$6'
        returning id" | sed "s/' '/NULL/g")
    echo `psql $pgConn -c "$sql" | awk '/^ / {print $1}' | tail -n 1`
}

function upsertPropagation {
    sql=$(echo "insert into propagation
            (relay_id, block_id, extended_at)
        values
            ('$1', $2, '$3')
        on conflict (relay_id, block_id) do update set
            extended_at='$3'
        returning id" | sed "s/' '/NULL/g")
    echo `psql $pgConn -c "$sql" | awk '/^ / {print $1}' | tail -n 1`
}

function upsertBattle {
    if [ `echo $4 | jq -r '.competitive'` == true ]
    then
        type="slot"
        against=""
        isWon=$(echo $4 | jq -r '.bvrfwinner')
        mySlot=$(echo $4 | jq -r '.slot')
        competitorJsonPaths=$(echo $4 | jq -r ".block_data[] | select(. != \"blockdata/10102/C_${3}.json\")")

        while read competitorJsonPath
        do
            competitorBlockHash=$(echo $competitorJsonPath | cut -c 19-82)
            competitorJson=$(getPoolToolJson $2 $competitorBlockHash)
            if [ `echo $competitorJson | jq -r '.slot'` != $mySlot ]; then type='height'; fi
            if [ $competitorBlockHash != $3 ]; then
                against="`echo $competitorJson | jq -r '.leaderPoolTicker'` $against"
            fi
        done <<< "$competitorJsonPaths"

        sql=$(echo "insert into battle
                (block_id, type, against, is_won)
            values
                ($1, '$type', '`$against | xargs`', $isWon)
            on conflict (block_id) do update set
                type='$type', against='$against', is_won='$isWon'
            returning id" | sed "s/' '/NULL/g")
        echo `psql $pgConn -c "$sql" | awk '/^ / {print $1}' | tail -n 1`
    fi
}

function getPoolToolJson {
    echo `wget -q -O - https://s3-us-west-2.amazonaws.com/data.pooltool.io/blockdata/${1:0:5}/C_${2}.json`
}

# Script start
echo "Searching for forged blocks within the last ${ago}..."
journalForgedLines=$(journalctl -o cat -u $coreServiceName -S -10m+$ago -g \"TraceForgedBlock\")

if [[ -z $journalForgedLines ]];
then
    echo "No blocks found."
    exit
else
    numBlocks=$(echo "$journalForgedLines" | wc -l)
    printf " %d block(s) found.\n\n" $numBlocks

    while read journalForgedLine
    do
        printf "Checking block %d / %d\n" $counter $numBlocks
        blockHash=$(echo ${journalForgedLine} | awk '{print $10}' | cut -c 2-65)
        blockHeight=$(echo ${journalForgedLine} | awk '{print $11}' | cut -c 1-11 | awk -F"E" 'BEGIN{OFMT="%10.1f"} {print $1 * (10 ^ $2)}')
        slot=$(echo ${journalForgedLine} | awk '{print $14}' | sed -E -e 's/]|\)//g' | awk -F"E" 'BEGIN{OFMT="%10.1f"} {print $1 * (10 ^ $2)}')
        blockForgedUTC=$(echo $journalForgedLine | awk '{print $2 " " $3 " " $4}' | cut -c 2-23)
        journalAdoptedLine=$(journalctl -o cat -u $coreServiceName -S -10m+$ago -g $blockHash.*TraceAdoptedBlock)
        blockAdoptedUTC=$(echo $journalAdoptedLine | awk '{print $2 " " $3 " " $4}' | cut -c 2-23)

        poolToolJson=$(getPoolToolJson $blockHeight $blockHash)
        poolToolMs=$(echo "$poolToolJson" | jq '.median')
        blockId=$(upsertBlock $slot $blockHeight $blockHash "$blockForgedUTC" "$blockAdoptedUTC" $poolToolMs)
        battleId=$(upsertBattle $blockId $blockHeight $blockHash "$poolToolJson")

        while read relayLine
        do
            relayArray=($(echo $relayLine | tr "," " "))
            journalExtendedLine=$(ssh -n $sshConn $sshUser@${relayArray[1]} "echo $sudoPassword | sudo -S journalctl -o cat -u $relayServiceName -S -10m+$ago -g extended.*$blockHash")
            chainExtendedUTC=$(echo $journalExtendedLine | head -n 1 | awk '{print $2 " " $3 " " $4}' | cut -c 2-23)
            propagId=$(upsertPropagation ${relayArray[0]} $blockId "$chainExtendedUTC")
        done <<< "$relays"

        counter=$((counter+1))
    done <<< "$journalForgedLines"
fi
