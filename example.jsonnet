// XXX rule label for recording rules as well as recording rules ?  see ruleSelector

local kp =
  (import 'kube-prometheus/main.libsonnet') +
  (import 'kube-prometheus/addons/anti-affinity.libsonnet') +
  (import 'kube-prometheus/addons/managed-cluster.libsonnet') +
  (import 'kube-prometheus/addons/all-namespaces.libsonnet') +
  // (import 'kube-prometheus/addons/custom-metrics.libsonnet') +
  // (import 'kube-prometheus/addons/external-metrics.libsonnet') +
  {
    values+:: {
      common+: {
        namespace: 'monitoring',
        platform: 'gke',
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
  };

// Hardcoded settings to extend PrometheusSpec
local customizePrometheusSpec(instance) =
  {
    prometheus+: {
      spec+: {
        priorityClassName: 'influxdata-infra-observability',
        retention: '24h',
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
    prometheus+: customizePrometheusSpec($.values.prometheus.name),
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
    prometheus+: customizePrometheusSpec($.values.prometheus.name),
  };


// Create namespace
{ '0/namespace': kp.kubePrometheus.namespace } +
// Render all manifests in prometheus operator except serviceMonitor and Protules rules
{
  ['1/prometheus-operator-' + name]: kp.prometheusOperator[name]
  for name in std.filter((function(name) name != 'serviceMonitor' && name != 'prometheusRule'), std.objectFields(kp.prometheusOperator))
} +
{ ['3/prometheus-k8s-' + name]: kp_k8s.prometheus[name] for name in std.objectFields(kp_k8s.prometheus) } +
{ ['3/prometheus-istio-' + name]: kp_istio.prometheus[name] for name in std.objectFields(kp_istio.prometheus) }


// // serviceMonitor and prometheusRule are separated so that they can be created after the CRDs are ready
// { '2/prometheus-operator-serviceMonitor': kp.prometheusOperator.serviceMonitor } +
// { '2/prometheus-operator-prometheusRule': kp.prometheusOperator.prometheusRule } +
// { '2/kube-prometheus-prometheusRule': kp.kubePrometheus.prometheusRule } +
// //{ ['alertmanager-' + name]: kp.alertmanager[name] for name in std.objectFields(kp.alertmanager) } +
// //{ ['blackbox-exporter-' + name]: kp.blackboxExporter[name] for name in std.objectFields(kp.blackboxExporter) } +
// //{ ['grafana-' + name]: kp.grafana[name] for name in std.objectFields(kp.grafana) } +
// //{ ['kube-state-metrics-' + name]: kp.kubeStateMetrics[name] for name in std.objectFields(kp.kubeStateMetrics) } +
// //{ ['kubernetes-' + name]: kp.kubernetesControlPlane[name] for name in std.objectFields(kp.kubernetesControlPlane) }
// //{ ['node-exporter-' + name]: kp.nodeExporter[name] for name in std.objectFields(kp.nodeExporter) } +
// { ['3/prometheus-' + name]: kp.prometheus[name] for name in std.objectFields(kp.prometheus) }
// //{ ['prometheus-adapter-' + name]: kp.prometheusAdapter[name] for name in std.objectFields(kp.prometheusAdapter) }



