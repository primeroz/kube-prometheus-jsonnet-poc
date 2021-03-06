// TODO: rule label for recording rules as well as recording rules ?  see ruleSelector
// TODO: Dashboards - take a long time to render ...
// TODO: Dashboard - filter out dashboards we don't need / want
// TODO: Prometheus - service monitor - exclude some namespaces for safety
// TODO: Prometheus - Ingestigate SLO rules with sloth
// TODO: Prometheus - Update /Add / Remove rules -


local k = import 'vendor/k8s-jsonnet-libs/gen/github.com/jsonnet-libs/k8s-libsonnet/1.19/main.libsonnet';
local kplib = import 'vendor/k8s-jsonnet-libs/gen/github.com/jsonnet-libs/kube-prometheus-libsonnet/0.8/main.libsonnet';

local addMixin = import 'kube-prometheus/lib/mixin.libsonnet';

// get with `minikube ip` command
//local minikube_ip = '192.168.39.7';
local minikube_ip = std.extVar('minikube_ip');

// prometheus jsonnet lib
local prom = kplib.monitoring.v1.prometheus;
local am = kplib.monitoring.v1.alertmanager;
local amcfg = kplib.monitoring.v1alpha1.alertmanagerConfig;
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

// Extra Mixins
local certManagerMixin = addMixin({
  name: 'certmanager',
  mixin: (import 'vendor/cert-manager-mixin/mixin.libsonnet') + {
    _config+: {
      certManagerCertExpiryDays: '15',
    },  // mixin configuration object
  },
});

// Kube Prometheus definition
local kp =
  (import 'kube-prometheus/main.libsonnet') +
  (import 'kube-prometheus/addons/anti-affinity.libsonnet') +
  (import 'kube-prometheus/addons/managed-cluster.libsonnet') +  // Do not monitor controlplane
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
          //alertmanager: '0.23.0',
          //grafana: '8.3.2',
          //nodeExporter: '1.2.2',
          //prometheusOperator: '0.53.1',
          //prometheusOperator: '0.51.2',
          //prometheus: '2.31.1',
        },
      },
      alertmanager+: {
        config: importstr 'alertmanager-config.yaml',
      },
      grafana+: {
        dashboards+: certManagerMixin.grafanaDashboards,
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
                         } +
                         {
                           [name]: super[name] + (if super[name].kind == 'CustomResourceDefinition' then { metadata+: { annotations+: { 'argocd.argoproj.io/sync-options': 'Replace=true' } } } else {})
                           for name in std.objectFields(super.prometheusOperator)
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
      local this = self,
      alertmanager+:
        am.metadata.withLabelsMixin({ alertmanager: 'main' }) +
        am.spec.withExternalUrl(std.format('http://%s:%s', [minikube_ip, '30903'])) +
        am.spec.withLogLevel('debug') +
        am.spec.alertmanagerConfigSelector.withMatchLabels({ alertmanager: 'main' }) +
        am.spec.withSecretsMixin(['alertmanager-tmpl-secrets']) +
        am.spec.withConfigMapsMixin(this.alertmanagerTemplatesConfigmap.metadata.name),
      // logformat
      // alertmanager custom secret for main configuration
      // priorityclass
      // configmaps // Templates ?
      alertmanagerTemplatesConfigmap+:
        local cm = k.core.v1.configMap;

        cm.new('influx-alertmanager-templates', { templates: importstr './alertmanager.templates' }) +
        cm.metadata.withNamespace(this.alertmanager.metadata.namespace) +
        cm.metadata.withLabelsMixin(this.alertmanager.metadata.labels),
      alertManagerPagerdutySreConf+:: {
        name: 'pagerduty-sre',
        pagerdutyConfigs: [{
          sendResolved: true,
          routingKey: {  // Since we use the events v2
            name: 'pagerduty-sre-secret',
            key: 'apiKey',
          },
          client: '{{ template "pagerduty.default.client" . }}',
          clientURL: '{{ template "pagerduty.default.clientURL" . }}',
          description: '{{ template "pagerduty.default.description" .}}',  // TODO '[#{{ .CommonLabels.k8s_environment | toUpper }}/{{ if .GroupLabels.k8s_cluster                  }}{{.GroupLabels.k8s_cluster | toUpper }}{{ else }}NoCluster{{ end }}][{{ .Status | toUpper }}{{ if eq .Status "firing" }}:{{ .Alerts.Firing | len }}{{ end }}]{{ .GroupLabels.SortedPairs.Values | join " " }}' // DEDUP on pagerduty ?
          //severity: '{{ if eq .GroupLabels.severity "critical" }}critical{{ else if eq .GroupLabels.severity "warning" }}warning{{ else }}info{{ end }}',
          //class: 'SampleClassFromAlertmanager',
          //group: '{{ if .GroupLabels.k8s_cluster }}{{.GroupLabels.k8s_cluster}}{{ else }}None{{ end }}',  // TODO
          //component: '{{ if .GroupLabels.component }}{{.GroupLabels.component}}{{ else }}None{{ end }}',  // TODO
          details: [],
          //details: [{
          //cluster: '{{ if .GroupLabels.cluster }}{{.GroupLabels.k8s_cluster}}{{ else }}None{{ end }}',  // TODO
          //environment: '{{ if .CommonLabels.environment }}{{.CommonLabels.k8s_environment}}{{ else }}None{{ end }}',
          //owner: '{{if .CommonLabels.label_influxdata_io_owner}}{{.CommonLabels.label_influxdata_io_owner}}{{else if .CommonLabels.influxdata_io_owner}}{{.CommonLabels.influxdata_io_owner}}{{else}}None{{end}}',
          //page: '{{ $do_page := "" }}{{ range .Alerts.Firing }}{{ range .Labels.SortedPairs }}{{ if (and (eq .Name "page") (eq .Value "false"))}}{{ $do_page = "false"}}{{ end }}{{ end }}{{ end }}{{ $do_page }}',
          //}],
          //links: '', can we attach a link to this object ?
        }],
      },
      alertManagerPagerdutyReceiverConf+::
        amcfg.new('alertmanager-pagerduty-sre') +
        amcfg.metadata.withNamespace(this.alertmanager.metadata.namespace) +
        amcfg.metadata.withLabelsMixin(this.alertmanager.metadata.labels) +
        //amcfg.metadata.withAnnotationsMixin(this.alertmanager.metadata.annotations),
        amcfg.spec.route.withContinue(false) +
        amcfg.spec.route.withGroupBy(['cluster', 'prometheus', 'namespace', 'alertname']) +
        amcfg.spec.route.withGroupWait('30s') +
        amcfg.spec.route.withGroupInterval('5m') +
        amcfg.spec.route.withRepeatInterval('1h') +
        amcfg.spec.route.withMatchers([{ name: 'prometheus', value: 'monitoring/k8s', regex: false }]) +
        amcfg.spec.route.withReceiver(this.alertManagerPagerdutySreConf.name) +
        amcfg.spec.withReceiversMixin(this.alertManagerPagerdutySreConf),
      serviceMonitor+:
        setInstanceForObject('k8s'),

      //policy/v1 is not available at least until version 1.20 and won't be removed until 1.25
      podDisruptionBudget+: {
        apiVersion: 'policy/v1beta1',
      },
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
      prom.metadata.withLabelsMixin({ prometheus: instance }) +
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
{ ['7/grafana-' + name]: kp.grafana[name] for name in std.objectFields(kp.grafana) } +
{ '10/certmanager.rules': certManagerMixin.prometheusRules }
// //{ ['prometheus-adapter-' + name]: kp.prometheusAdapter[name] for name in std.objectFields(kp.prometheusAdapter) }



