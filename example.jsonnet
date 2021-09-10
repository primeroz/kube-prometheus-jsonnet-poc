// TODO: rule label for recording rules as well as recording rules ?  see ruleSelector
// TODO: Dashboards - take a long time to render ...
// TODO: Dashboards - split up in multiple ConfigMaps object or hit the limit of 1MB ( is alreayd split )
// TODO: Dashboard - filter out dashboards we don't need / want
// TODO: Prometheus - service monitor - exclude some namespaces for safety
// TODO: Prometheus - Ingestigate SLO rules


local k = import 'vendor/k8s-jsonnet-libs/gen/github.com/jsonnet-libs/k8s-libsonnet/1.19/main.libsonnet';
local kplib = import 'vendor/k8s-jsonnet-libs/gen/github.com/jsonnet-libs/kube-prometheus-libsonnet/0.8/main.libsonnet';

// get with `minikube ip` command
//local minikube_ip = '192.168.39.7';
local minikube_ip = std.extVar('minikube_ip');

// prometheus jsonnet lib
local prom = kplib.monitoring.v1.prometheus;
local am = kplib.monitoring.v1.alertmanager;
local sm = kplib.monitoring.v1.serviceMonitor;


local setInstanceForObject(instance) =
  {
    metadata+: {
      labels+: {
        prometheus: instance,
      },
    },
  };

local setEndpointsIntevalForServiceMonitor(endpoints, interval) =
  std.map(
    function(item)
      if (std.objectHas(item, 'interval'))
      then item { interval: interval }
      else item
    , endpoints
  );

// Kube Prometheus definition
local kp =
  (import 'kube-prometheus/main.libsonnet') +
  (import 'kube-prometheus/addons/anti-affinity.libsonnet') +
  //(import 'kube-prometheus/addons/managed-cluster.libsonnet') + // this is not a managed cluster
  (import 'kube-prometheus/addons/all-namespaces.libsonnet') +
  // Note that NodePort type services is likely not a good idea for your production use case, it is only used for demonstration purposes here.
  (import 'kube-prometheus/addons/node-ports.libsonnet') +
  // (import 'kube-prometheus/addons/custom-metrics.libsonnet') +
  // (import 'kube-prometheus/addons/external-metrics.libsonnet') +
  {
    values+:: {
      common+: {
        namespace: 'monitoring',
        platform: 'kubeadm',
        versions+: {
          alertmanager: '0.23.0',
          grafana: '8.1.2',
          nodeExporter: '1.2.2',
          //prometheusOperator: '0.50.0',
          prometheus: '2.29.2',
        },
      },
      //alertmanager+: {
      //config: importstr 'alertmanager-config.yaml',
      //},
      grafana+: {
        config: {  // http://docs.grafana.org/installation/configuration/
          sections: {
            // Do not require grafana users to login/authenticate
            'auth.anonymous': { enabled: true },
          },
        },
      },
      kubernetesControlPlane+: {
        kubeProxy: true,
        mixin+: {
          //ruleLabels: $.values.common.ruleLabels,
          _config+: {
            cadvisorSelector: 'job="kubelet", metrics_path="/metrics/cadvisor"',
            kubeletSelector: 'job="kubelet", metrics_path="/metrics"',
            kubeStateMetricsSelector: 'job="kube-state-metrics"',
            nodeExporterSelector: 'job="node-exporter"',
            kubeSchedulerSelector: 'job="kube-scheduler"',
            kubeControllerManagerSelector: 'job="kube-controller-manager"',
            kubeApiserverSelector: 'job="apiserver"',
            podLabel: 'pod',
            runbookURLPattern: 'https://runbooks.prometheus-operator.dev/runbooks/kubernetes/%s',
            diskDeviceSelector: 'device=~"mmcblk.p.+|nvme.+|rbd.+|sd.+|vd.+|xvd.+|dm-.+|dasd.+"',
            hostNetworkInterfaceSelector: 'device!~"veth.+"',
          },
        },
      },
      prometheus+: {
        resources: {
          requests: { cpu: '150m', memory: '400Mi' },
          limits: { cpu: '2500m', memory: '4000Mi' },
        },
        enableFeatures: [],  // XXX ?
        externalLabels+: {
          cluster: 'someCluster',
        },
        ruleSelector: {
          matchExpressions: [
            {
              key: 'prometheus',
              operator: 'In',
              values: [$.values.prometheus.name],
            },
            {
              key: 'role',
              operator: 'In',
              values: [
                'alert-rules',
                'recording-rules',
              ],
            },
          ],
        },
      },
    },

    /// JSONNET OVVERRIDES START HERE
    prometheusOperator+: {
      serviceMonitor+:
        setInstanceForObject('k8s'),
    },
    prometheus+: {
      // backward compatible for older k8s
      clusterRole+: {
        rules+: [
          {
            apiGroups: ['extensions'],
            resources: ['ingresses'],
            verbs: ['get', 'list', 'watch'],
          },
        ],
      },
    },
    kubeStateMetrics+: {
      serviceMonitor+:
        setInstanceForObject('k8s'),
    },
    grafana+: {
      serviceMonitor+:
        setInstanceForObject('k8s'),
    },
    alertmanager+: {
      alertmanager+:
        am.spec.withExternalUrl(std.format('http://%s:%s', [minikube_ip, '30903'])) +
        am.spec.withLogLevel('debug'),
      serviceMonitor+:
        setInstanceForObject('k8s'),
    },
    nodeExporter+: {
      serviceMonitor+:
        setInstanceForObject('k8s') +
        {
          spec+: {
            // Override Interval for nodeExporter ( PR Upstream ? )
            endpoints: setEndpointsIntevalForServiceMonitor(super.endpoints, '30s'),
          },
        },
    },
    kubernetesControlPlane+: {
      //[name]: super[name]
      [name]: super[name] + (if super[name].kind == 'ServiceMonitor' || super[name].kind == 'PodMonitor' then setInstanceForObject('k8s') else {})
      for name in std.objectFields(super.kubernetesControlPlane)
    },
    /// JSONNET OVVERRIDES END HERE
  };

// Hardcoded settings to extend PrometheusSpec
local customizePrometheusSpec(instance, port) =
  {
    //priorityClassName: 'influxdata-infra-observability',
    //local thisPrometheusSelectorMatchExpression =
    //  {
    //    key: 'prometheus',
    //    operator: 'In',
    //    values: [instance],
    //  },
    prometheus+:
      prom.spec.withRetention('24h') +
      prom.spec.withRetentionSize('500MB') +
      prom.spec.withExternalUrl(std.format('http://%s:%s', [minikube_ip, port])) +
      prom.spec.serviceMonitorSelector.withMatchLabelsMixin({ prometheus: instance }) +
      prom.spec.podMonitorSelector.withMatchLabelsMixin({ prometheus: instance }) +
      prom.spec.probeSelector.withMatchLabelsMixin({ prometheus: instance }),
  };

// Main prometheus instance
// TODO: Convert to main object https://github.com/prometheus-operator/kube-prometheus/blob/main/jsonnet/kube-prometheus/main.libsonnet#L89
local kp_k8s =
  kp
  {
    values+:: {
      prometheus+: {
        name: 'k8s',
        replicas: 1,  // minikube only one replica
        externalLabels+: {
          instance: 'k8s',
        },
      },
    },
    prometheus+: customizePrometheusSpec($.values.prometheus.name, '30900') +
                 {
                   serviceMonitor+:
                     setInstanceForObject('k8s'),
                 },
  };

// Istio prometheus instance
local kp_istio =
  kp
  {
    values+:: {
      prometheus+: {
        name: 'istio',
        replicas: 1,
        externalLabels+: {
          instance: 'istio',
        },
      },
    },
    prometheus+: customizePrometheusSpec($.values.prometheus.name, '30901') +
                 {
                   service+: {
                     spec+: {
                       ports: [{ name: 'web', port: 9090, targetPort: 'web', nodePort: 30901 }],
                       type: 'NodePort',
                     },
                   },
                 } +
                 {
                   serviceMonitor+:
                     setInstanceForObject('istio'),
                 },
  };


// Create namespace
{ '0/namespace': kp.kubePrometheus.namespace } +
// Render all manifests in prometheus operator except serviceMonitor and Protules rules
{
  ['1/prometheus-operator-' + name]: kp.prometheusOperator[name]
  for name in std.filter((function(name) name != 'serviceMonitor' && name != 'prometheusRule'), std.objectFields(kp.prometheusOperator))
} +
// serviceMonitor and prometheusRule are separated so that they can be created after the CRDs are ready
{ '2/prometheus-operator-serviceMonitor': kp.prometheusOperator.serviceMonitor } +
{ '2/prometheus-operator-prometheusRule': kp.prometheusOperator.prometheusRule } +
{ '2/kube-prometheus-prometheusRule-k8s': kp.kubePrometheus.prometheusRule + setInstanceForObject('k8s') + { metadata+: { name: 'kube-prometheus-rules-k8s' } } } +
{ '2/kube-prometheus-prometheusRule-istio': kp.kubePrometheus.prometheusRule + setInstanceForObject('istio') + { metadata+: { name: 'kube-prometheus-rules-istio' } } } +
// Monitoring workloads
{ ['3/node-exporter-' + name]: kp.nodeExporter[name] for name in std.objectFields(kp.nodeExporter) }
// Prometheus instances
{ ['4/prometheus-k8s-' + name]: kp_k8s.prometheus[name] for name in std.objectFields(kp_k8s.prometheus) } +
{ ['4/prometheus-istio-' + name]: kp_istio.prometheus[name] for name in std.objectFields(kp_istio.prometheus) } +
{ ['4/alertmanager-' + name]: kp.alertmanager[name] for name in std.objectFields(kp.alertmanager) } +
// //{ ['blackbox-exporter-' + name]: kp.blackboxExporter[name] for name in std.objectFields(kp.blackboxExporter) } +
{ ['5/kube-state-metrics-' + name]: kp.kubeStateMetrics[name] for name in std.objectFields(kp.kubeStateMetrics) } +
{ ['6/kubernetes-' + name]: kp.kubernetesControlPlane[name] for name in std.objectFields(kp.kubernetesControlPlane) } +
{ ['7/grafana-' + name]: kp.grafana[name] for name in std.objectFields(kp.grafana) }
// //{ ['prometheus-adapter-' + name]: kp.prometheusAdapter[name] for name in std.objectFields(kp.prometheusAdapter) }



