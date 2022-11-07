export CORES=$1
export MEMORY=$2
# export TIMESTAMP=`date +%y-%m-%d-%H-%M-%S`

export CORES="${CORES:-4}"
export MEMORY="${MEMORY:-8}"

# calculate 30% overhead and ceil
export MEMORY_OVERHEAD=$(((${MEMORY}*30+(100-1))/100))
export EXEC_MEMORY=$((${MEMORY}-${MEMORY_OVERHEAD}))

export EKSCLUSTER_NAME="${EKSCLUSTER_NAME:-aws-blog}"
export EMRCLUSTER_NAME="${EMRCLUSTER_NAME:-${EKSCLUSTER_NAME}-emr}"

export ACCOUNTID="${ACCOUNTID:-$(aws sts get-caller-identity --query Account --output text)}"
export AWS_REGION="${AWS_REGION:-$(curl -s 169.254.169.254/latest/dynamic/instance-identity/document | jq -r '.region')}"
export S3BUCKET="${S3BUCKET:-${EMRCLUSTER_NAME}-${ACCOUNTID}-${AWS_REGION}}"

export VIRTUAL_CLUSTER_ID=$(aws emr-containers list-virtual-clusters --query "virtualClusters[?name == '${EMRCLUSTER_NAME}-ca' && state == 'RUNNING'].id" --output text)
export EMR_ROLE_ARN=arn:aws:iam::$ACCOUNTID:role/$EMRCLUSTER_NAME-execution-role
export ECR_URL="$ACCOUNTID.dkr.ecr.$AWS_REGION.amazonaws.com"

aws emr-containers start-job-run \
  --virtual-cluster-id $VIRTUAL_CLUSTER_ID \
  --name ca-benchmark-${CORES}vcpu-${MEMORY}gb \
  --execution-role-arn $EMR_ROLE_ARN \
  --release-label emr-6.5.0-latest \
  --job-driver '{
  "sparkSubmitJobDriver": {
      "entryPoint": "local:///usr/lib/spark/examples/jars/eks-spark-benchmark-assembly-1.0.jar",
      "entryPointArguments":["s3://blogpost-sparkoneks-us-east-1/blog/BLOG_TPCDS-TEST-3T-partitioned","s3://'$S3BUCKET'/EMRONEKS_TPCDS-TEST-3T-RESULT-CA-'TIMESTAMP'","/opt/tpcds-kit/tools","parquet","3000","1","false","q70-v2.4,q82-v2.4,q64-v2.4","true"],
      "sparkSubmitParameters": "--class com.amazonaws.eks.tpcds.BenchmarkSQL --conf spark.executor.instances=50 --conf spark.driver.cores='$CORES' --conf spark.driver.memory='$EXEC_MEMORY'g --conf spark.executor.cores='$CORES' --conf spark.executor.memory='$EXEC_MEMORY'g"}}' \
  --configuration-overrides '{
    "applicationConfiguration": [
      {
        "classification": "spark-defaults", 
        "properties": {
          "spark.kubernetes.node.selector.app": "caspark",

          "spark.kubernetes.container.image":  "'$ECR_URL'/eks-spark-benchmark:emr6.5",
          "spark.kubernetes.driver.podTemplateFile": "s3://'$S3BUCKET'/pod-template/ca-driver-pod-template.yaml",
          "spark.kubernetes.executor.podTemplateFile": "s3://'$S3BUCKET'/pod-template/ca-executor-pod-template.yaml",
          "spark.network.timeout": "2000s",
          "spark.executor.heartbeatInterval": "300s",
          "spark.executor.memoryOverhead": "'$MEMORY_OVERHEAD'G",
          "spark.driver.memoryOverhead": "'$MEMORY_OVERHEAD'G",
          "spark.kubernetes.executor.podNamePrefix": "ca-'$CORES'vcpu-'$MEMORY'gb",
          "spark.executor.defaultJavaOptions": "-verbose:gc -XX:+UseG1GC",
          "spark.driver.defaultJavaOptions": "-verbose:gc -XX:+UseG1GC",
          
          
          "spark.ui.prometheus.enabled":"true",
          "spark.executor.processTreeMetrics.enabled":"true",
          "spark.kubernetes.driver.annotation.prometheus.io/scrape":"true",
          "spark.kubernetes.driver.annotation.prometheus.io/path":"/metrics/executors/prometheus/",
          "spark.kubernetes.driver.annotation.prometheus.io/port":"4040",
          "spark.kubernetes.driver.service.annotation.prometheus.io/scrape":"true",
          "spark.kubernetes.driver.service.annotation.prometheus.io/path":"/metrics/driver/prometheus/",
          "spark.kubernetes.driver.service.annotation.prometheus.io/port":"4040",
          "spark.metrics.conf.*.sink.prometheusServlet.class":"org.apache.spark.metrics.sink.PrometheusServlet",
          "spark.metrics.conf.*.sink.prometheusServlet.path":"/metrics/driver/prometheus/",
          "spark.metrics.conf.master.sink.prometheusServlet.path":"/metrics/master/prometheus/",
          "spark.metrics.conf.applications.sink.prometheusServlet.path":"/metrics/applications/prometheus/"
         }}
    ]}'
