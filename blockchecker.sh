#!/bin/bash

# Script arguments
cfg=$1
ago=${2:-'4h'}

if [ -z $cfg ]; then echo "Please pass the path to the configuation as the first argument."; exit; fi
if ! [ -r $cfg ]; then echo "Error: '$cfg' not readable."; exit; fi

# Script variables
source $cfg
pgConn="-h $PGHOST -p $PGPORT -d $PGDATABASE -U $PGUSER"
relays=$(cat $ansibleInventoryFile | yq | jq -r '.relays.hosts[].ansible_host')
counter=1

# Function definitions
function upsertBlock { # args: slot blockHeight blockHash blockForgedUTC blockAdoptedUTC poolToolMs
    epoch=$(echo "(((85363200 + $1) / 86400) / 5)" | bc)
    if [ "x$6" == "x" ]; then ms=NULL; else ms=$6; fi
    sql=$(echo "insert into block
            (slot, epoch, height, hash, forged_at, adopted_at, pooltool_ms)
        values
            ($1, $epoch, $2, '$3', '$4', '$5', $ms)
        on conflict (slot) do update set
            height=$2, hash='$3', forged_at='$4', adopted_at='$5', pooltool_ms=$ms
        returning id" | sed "s/' '/NULL/g")
    echo `psql $pgConn -c "$sql" | awk '/^ / {print $1}' | tail -n 1`
}

function upsertPropagation { # args: blockId relay extendedAt
    sql=$(echo "insert into propagation
            (block_id, hostname, extended_at)
        values
            ($1, '$2', '$3')
        on conflict (block_id, hostname) do update set
            extended_at='$3'
        returning id" | sed "s/' '/NULL/g")
    echo `psql $pgConn -c "$sql" | awk '/^ / {print $1}' | tail -n 1`
}

function upsertBattle { # args: blockId blockHeight blockHash poolToolJson slot
    if [ -z "$4" ]; then json="{\"competitive\": true, \"bvrfwinner\": false, \"slot\": $5}"; else json=$4; fi
    if [ "`echo $json | jq -r '.competitive'`" == "true" ]
    then
        type="slot"
        against=()
        isWon=$(echo $json | jq -r '.bvrfwinner')
        mySlot=$(echo $json | jq -r '.slot')

        if [[ -n "$4" ]];
        then
            competitorJsonPaths=$(echo $json | jq -r ".block_data[] | select(. != \"blockdata/${2:0:5}/C_${3}.json\")");
        fi

        if [ -n "$competitorJsonPaths" ]
        then
            while read competitorJsonPath
            do
                competitorBlockHash=$(echo $competitorJsonPath | cut -c 19-82)
                competitorJson=$(getPoolToolJson $2 $competitorBlockHash)
                if [ `echo $competitorJson | jq -r '.slot'` != $mySlot ]; then type='height'; fi
                if [ $competitorBlockHash != $3 ]; then
                    against+=(`echo $competitorJson | jq -r '.leaderPoolTicker'`)
                fi
            done <<< "$competitorJsonPaths"
        else
            against+="###"
        fi

        sql=$(echo "insert into battle
                (block_id, type, against, is_won)
            values
                ($1, '$type', '`echo "${against[@]}"`', $isWon)
            on conflict (block_id) do update set
                type='$type', against='`echo "${against[@]}"`', is_won='$isWon'
            returning id" | sed "s/' '/NULL/g")
        sqlResult=$(psql $pgConn -c "$sql" | awk '/^ / {print $1}' | tail -n 1)
        notifyBattle $1 $2 $3 $5 $type $against $isWon
        echo $sqlResult
    fi
}

function notifyBattle { # args: blockId blockHeight blockHash slot type against isWon
    if [ -n "$notifyEmailAddress" ]
    then
        if [ "$7" == "true" ]; then result="won"; else result="lost"; fi
        if [ "$notifySlotBattle" == "$result" ] ||
           [ "$notifySlotBattle" == "both" ] ||
           [ "$notifyHeightBattle" == "$result" ] ||
           [ "$notifyHeightBattle" == "both" ]
        then
            echo "${5^} battle for height $2 was $result. Sending notification."
            printf "Type:    %s\nAgainst: %s\nResult:  %s\n\nID:      %s\nHeight:  %s\nHash:    %s\nSlot:    %d" $5 $6 ${result^} $1 $2 $3 $4 | \
            mail -s "${result^} $5 battle against $6" $notifyEmailAddress
        else
            echo " ${4^} battle for $3 was $result. Not sending notification."
        fi
    fi
}

function getPoolToolJson { # args: blockHeight blockHash
    echo "`wget -q -O - https://s3-us-west-2.amazonaws.com/data.pooltool.io/blockdata/${1:0:5}/C_${2}.json`"
}

function runAnsibleCommand { # args: hostname command
    echo "`ansible $1 -b -i $ansibleInventoryFile --vault-id $ansibleVaultId@$ansibleVaultPassFile -m ansible.builtin.command -a "$2" | tail -n +2`"
}

function runAnsiblePing { # args: hostname
    echo "`ansible $1 -b -i $ansibleInventoryFile --vault-id $ansibleVaultId@$ansibleVaultPassFile -m ansible.builtin.ping`"
}

function testScript
{
    sqlResult=$(psql $pgConn -c "select version()")
    echo "$sqlResult"
    echo ""

    while read relay
    do
        pingResult=$(runAnsiblePing $relay)
        echo "$pingResult"
    done <<< "$relays"
    exit;
}

# Script start
if [ "$ago" == "test" ]; then testScript; exit; fi
echo "Searching for forged blocks within the last ${ago}..."
journalForgedLines=$(journalctl -o cat -u $coreServiceName -S -10m+$ago -g "TraceForgedBlock")

if [[ -z $journalForgedLines ]];
then
    echo "No blocks found."
    exit
else
    numBlocks=$(echo "$journalForgedLines" | wc -l)
    printf " %d block(s) found.\n\n" $numBlocks

    while read journalForgedLine
    do
        blockHash=$(echo ${journalForgedLine} | awk '{print $10}' | cut -c 2-65)
        printf "Checking %s (%d / %d)\n" $blockHash $counter $numBlocks
        blockHeight=$(echo ${journalForgedLine} | awk '{print $11}' | cut -c 1-11 | awk -F"E" 'BEGIN{OFMT="%10.1f"} {print $1 * (10 ^ $2)}')
        slot=$(echo ${journalForgedLine} | awk '{print $14}' | sed -E -e 's/]|\)//g' | awk -F"E" 'BEGIN{OFMT="%10.1f"} {print $1 * (10 ^ $2)}')
        blockForgedUTC=$(echo $journalForgedLine | awk '{print $2 " " $3 " " $4}' | cut -c 2-23)
        journalAdoptedLine=$(journalctl -o cat -u $coreServiceName -S -10m+$ago -g $blockHash.*TraceAdoptedBlock)
        blockAdoptedUTC=$(echo $journalAdoptedLine | awk '{print $2 " " $3 " " $4}' | cut -c 2-23)
        poolToolJson=$(getPoolToolJson $blockHeight $blockHash)
        poolToolMs=$(echo "$poolToolJson" | jq '.median')

        if [ "$journalAdoptedLine" != "non-zero return code" ];
        then
            blockId=$(upsertBlock $slot $blockHeight $blockHash "$blockForgedUTC" "$blockAdoptedUTC" $poolToolMs)
            battleId=$(upsertBattle $blockId $blockHeight $blockHash "$poolToolJson" $slot)
        fi

        while read relay
        do
            journalExtendedLine=$(runAnsibleCommand $relay "journalctl -o cat -u $relayServiceName -S -10m+$ago -g extended.*$blockHash")

            if [ "$journalExtendedLine" != "non-zero return code" ];
            then
                chainExtendedUTC=$(echo $journalExtendedLine | head -n 1 | awk '{print $2 " " $3 " " $4}' | cut -c 2-23)
                propagId=$(upsertPropagation $blockId $relay "$chainExtendedUTC")
            fi
        done <<< "$relays"

        counter=$((counter+1))
    done <<< "$journalForgedLines"
fi
