#!/bin/bash

if [ $# -eq 0 ]
then
  echo "No arguments supplied"
  exit
fi
date=`date -u '+%Y%m%d%H%M'`
start=`date -u +%s`
start_timestamp=`date -u +'%F %T'`
scripts=`realpath $0`
folder=`dirname $scripts`
autoscaling_folder=$folder/../autoscaling
monitoring_folder=$folder/../monitoring
logs_folder=$folder/../logs
cd $autoscaling_folder/clusters/$1
cluster_id=`cat cluster_id`
echo $date >> $logs_folder/delete_${cluster_id}.log 2>&1
if [ -f "currently_destroying" ] && [[ $2 != FORCE ]]
then 
    echo "The cluster is already being destroyed"
else
  echo $1 >> currently_destroying
  if [ -f $monitoring_folder/activated ]
  then
    source $monitoring_folder/env
    mysql -u $ENV_MYSQL_USER -p$ENV_MYSQL_PASS -e "use $ENV_MYSQL_DATABASE_NAME; UPDATE cluster_log.clusters SET started_deletion='$start_timestamp',state='deleting',deletion_tries=deletion_tries+1 WHERE id='$cluster_id'" >> $logs_folder/delete_${cluster_id}.log 2>&1
  fi
  if [ -f inventory ] 
  then
    echo `date -u '+%Y%m%d%H%M'` >> $logs_folder/delete_${cluster_id}.log 2>&1
    $folder/cleanup.sh $1 >> $logs_folder/delete_${cluster_id}.log 2>&1
    status_initial_deletion=$?
  else
    echo "The inventory file was never created, terraform failed before that step" >> $logs_folder/delete_${cluster_id}.log 2>&1
    status_initial_deletion=0
  fi
  if [ $status_initial_deletion -ne 0 ] && [[ $2 == FORCE ]]
  then
    echo `date -u '+%Y%m%d%H%M'` >> $logs_folder/delete_${cluster_id}.log 2>&1
    $folder/cleanup.sh $1 FORCE >> $logs_folder/delete_${cluster_id}.log 2>&1
    status_initial_deletion=$?
  fi
  i=0
  echo `date -u '+%Y%m%d%H%M'` >> $logs_folder/delete_${cluster_id}.log 2>&1
  terraform destroy -auto-approve -parallelism 5 >> $logs_folder/delete_${cluster_id}.log 2>&1
  status_terraform_deletion=$?
  while [ $i -lt 5 ] && [ $status_terraform_deletion -ne 0 ]
  do
    indexerror=`tail $logs_folder/delete_${cluster_id}.log -n 25 | grep "Error:" | grep "Invalid index" | wc -l`
    if [ $indexerror -ne 0 ]
    then
        actualSize=`tail $logs_folder/delete_${cluster_id}.log -n 25 | grep "data.oci_core_instance_pool_instances.instance_pool_instances\[0\].instances" | grep "is list of object with" | awk '{print $10}' | tail -n 1`
        if [[ "$actualSize" == "" ]] ; then actualSize=0; fi
        tmp_serial=`cat terraform.tfstate | grep "\"serial\"" | awk '{print $2}'`
        serial=${tmp_serial::-1}
        tmp_size=`cat terraform.tfstate | grep "\"size\"" | awk '{print $2}'`
        size=${tmp_size::-1}
        sed "s~\"serial\": $serial~\"serial\": $((serial+1))~g;s~\"size\": $size~\"size\": ${actualSize}~g" terraform.tfstate > /tmp/$1.tfstate
        terraform state push /tmp/$1.tfstate
        sed "s~variable \"node_count\" { default=\"$size\"~variable \"node_count\" { default=\"$actualSize\"~g" variables.tf > /tmp/$1_variables.tf
        mv /tmp/$1_variables.tf variables.tf
    fi
    echo `date -u '+%Y%m%d%H%M'` >> $logs_folder/delete_${cluster_id}.log 2>&1
    terraform init >> $logs_folder/delete_${cluster_id}.log 2>&1
    terraform destroy -auto-approve >> $logs_folder/delete_${cluster_id}.log 2>&1
    status_terraform_deletion=$?
    ((i++))
    if [ $status_terraform_deletion -eq 0 ]; then
      break
    fi
    sleep 120
  done 
  end=`date -u +%s`
  end_timestamp=`date -u +'%F %T'`
  runtime=$((end-start))
  if [ $status_initial_deletion -ne 0 ] 
  then
    echo "ANSIBLE initial cleanup has failed. This may have been resolved in the retry" >> $logs_folder/delete_${cluster_id}.log 2>&1
    if [ -f $monitoring_folder/activated ]
    then
      mysql -u $ENV_MYSQL_USER -p$ENV_MYSQL_PASS -e "use $ENV_MYSQL_DATABASE_NAME; INSERT INTO cluster_log.errors_timeserie (cluster_id,state,error_log,error_type,created_on_m) VALUES ('$cluster_id','deletion','$logs_folder/delete_${cluster_id}.log','Ansible Cleanup may not have finished properly `tail $logs_folder/delete_${cluster_id}.log | grep Error`','$end_timestamp');" >> $logs_folder/delete_${cluster_id}.log 2>&1
    fi
  fi
  if [ $status_terraform_deletion -eq 0 ]
  then
    echo "Successfully deleted cluster $1 in $runtime seconds"
    if [ -f $monitoring_folder/activated ]
    then
      mysql -u $ENV_MYSQL_USER -p$ENV_MYSQL_PASS -e "use $ENV_MYSQL_DATABASE_NAME; UPDATE cluster_log.clusters SET deleted='$end_timestamp',state='deleted',deletion_time=SEC_TO_TIME($runtime),deletion_log='$logs_folder/delete_${cluster_id}.log',deletion_tries=deletion_tries+1 WHERE id='$cluster_id'" >> $logs_folder/delete_${cluster_id}.log 2>&1
      mysql -u $ENV_MYSQL_USER -p$ENV_MYSQL_PASS -e "use $ENV_MYSQL_DATABASE_NAME; UPDATE cluster_log.nodes SET started_deletion='$start_timestamp',deleted='$end_timestamp',state='deleted' WHERE cluster_id='$cluster_id'" >> $logs_folder/delete_${cluster_id}.log 2>&1
    fi
    nodes=`scontrol show topology $1 2>&1 | grep Nodes | awk '{print $NF}' | sed "s/Nodes=//"`
    if [[ `echo $nodes | wc -w` > 0 ]]
    then
        for node in `scontrol show hostname $nodes 2>&1`
        do
            echo "Cleaning up node " $node
            /opt/oci-hpc/bin/resize.sh remove_unreachable --nodes $node 
        done
    fi
    cd
    rm -rf $autoscaling_folder/clusters/$1 | tee -a $logs_folder/delete_${cluster_id}.log 2>&1
  else
    echo "Could not delete cluster $1 in 5 tries (Time: $runtime seconds)"
    rm currently_destroying
    if [ -f $monitoring_folder/activated ]
    then
      mysql -u $ENV_MYSQL_USER -p$ENV_MYSQL_PASS -e "use $ENV_MYSQL_DATABASE_NAME; INSERT INTO cluster_log.errors_timeserie (cluster_id,state,error_log,error_type,created_on_m) VALUES ('$cluster_id','deletion','$logs_folder/delete_${cluster_id}.log','`tail $logs_folder/delete_${cluster_id}.log | grep Error`','$end_timestamp');" >> $logs_folder/delete_${cluster_id}.log 2>&1
      mysql -u $ENV_MYSQL_USER -p$ENV_MYSQL_PASS -e "use $ENV_MYSQL_DATABASE_NAME; UPDATE cluster_log.clusters SET started_deletion=NULL,state='running' WHERE id='$cluster_id'" >> $logs_folder/delete_${cluster_id}.log 2>&1
    fi
  fi
fi