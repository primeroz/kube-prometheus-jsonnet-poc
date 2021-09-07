// XXX rule label for recording rules as well as recording rules ?  see ruleSelector

local minikube_ip = '192.168.39.44';

local kp =
  (import 'kube-prometheus/main.libsonnet') +
  (import 'kube-prometheus/addons/anti-affinity.libsonnet') +
  (import 'kube-prometheus/addons/managed-cluster.libsonnet') +
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
      prometheus+: {
        version: '2.29.2',
        resources: {
          requests: { cpu: '250m', memory: '400Mi' },
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
    alertmanager+: {
      alertmanager+: {
        // Reference info: https://github.com/coreos/prometheus-operator/blob/master/Documentation/api.md#alertmanagerspec
        spec+: {
          externalUrl: std.format('http://%s:%s', [minikube_ip, '30903']),
          logLevel: 'debug',  // So firing alerts show up in log
        },
      },
    },
  };

// Hardcoded settings to extend PrometheusSpec
local customizePrometheusSpec(instance, port) =
  {
    prometheus+: {
      spec+: {
        //priorityClassName: 'influxdata-infra-observability',
        retention: '24h',  // Bytes and Time
        externalUrl: std.format('http://%s:%s', [minikube_ip, port]),
        thisPrometheusSelector:: {
          matchExpressions:
            [
              {
                key: 'prometheus',
                operator: 'In',
                values: [instance],
              },
            ],
        },
        serviceMonitorSelector: $.prometheus.spec.thisPrometheusSelector,
        podMonitorSelector: $.prometheus.spec.thisPrometheusSelector,
        probeSelector: $.prometheus.spec.thisPrometheusSelector,
      },
    },
  };

// Main prometheus instance
local kp_k8s =
  kp
  {
    values+:: {
      prometheus+: {
        name: 'k8s',
        externalLabels+: {
          instance: 'k8s',
        },
      },
    },
    prometheus+: customizePrometheusSpec($.values.prometheus.name, '30900'),
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
//{ '2/prometheus-operator-serviceMonitor': kp.prometheusOperator.serviceMonitor } +
//{ '2/prometheus-operator-prometheusRule': kp.prometheusOperator.prometheusRule } +
//{ '2/kube-prometheus-prometheusRule': kp.kubePrometheus.prometheusRule } +
// Monitoring workloads
{ ['3/node-exporter-' + name]: kp.nodeExporter[name] for name in std.objectFields(kp.nodeExporter) }
// Prometheus instances
{ ['4/prometheus-k8s-' + name]: kp_k8s.prometheus[name] for name in std.objectFields(kp_k8s.prometheus) } +
{ ['4/prometheus-istio-' + name]: kp_istio.prometheus[name] for name in std.objectFields(kp_istio.prometheus) } +
{ ['4/alertmanager-' + name]: kp.alertmanager[name] for name in std.objectFields(kp.alertmanager) }
// //{ ['blackbox-exporter-' + name]: kp.blackboxExporter[name] for name in std.objectFields(kp.blackboxExporter) } +
//{ ['5/grafana-' + name]: kp.grafana[name] for name in std.objectFields(kp.grafana) },
// //{ ['kube-state-metrics-' + name]: kp.kubeStateMetrics[name] for name in std.objectFields(kp.kubeStateMetrics) } +
// //{ ['kubernetes-' + name]: kp.kubernetesControlPlane[name] for name in std.objectFields(kp.kubernetesControlPlane) }
// { ['3/prometheus-' + name]: kp.prometheus[name] for name in std.objectFields(kp.prometheus) }
// //{ ['prometheus-adapter-' + name]: kp.prometheusAdapter[name] for name in std.objectFields(kp.prometheusAdapter) }



