{{/* Chart name. */}}
{{- define "stroom-proxy.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Full name, including the colour, so blue and green releases don't clash. */}}
{{- define "stroom-proxy.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" (include "stroom-proxy.name" .) (include "stroom-proxy.colour" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/* Colour, validated: lower-case letters and digits, starting with a letter. */}}
{{- define "stroom-proxy.colour" -}}
{{- $colour := required "colour is required (e.g. blue or green)" .Values.colour }}
{{- if not (regexMatch "^[a-z][a-z0-9]{0,9}$" $colour) }}
{{- fail (printf "colour %q must be 1-10 lower-case letters or digits, starting with a letter" $colour) }}
{{- end }}
{{- $colour }}
{{- end }}

{{- define "stroom-proxy.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Labels that select this release's pods. Must not change after install. */}}
{{- define "stroom-proxy.selectorLabels" -}}
app.kubernetes.io/name: {{ include "stroom-proxy.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
stroom-proxy/colour: {{ include "stroom-proxy.colour" . }}
{{- end }}

{{- define "stroom-proxy.labels" -}}
helm.sh/chart: {{ include "stroom-proxy.chart" . }}
{{ include "stroom-proxy.selectorLabels" . }}
app.kubernetes.io/version: {{ include "stroom-proxy.imageTag" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "stroom-proxy.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "stroom-proxy.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "stroom-proxy.imageTag" -}}
{{- default .Chart.AppVersion .Values.image.tag }}
{{- end }}

{{/* repository@digest when a digest is set, otherwise repository:tag. */}}
{{- define "stroom-proxy.imageRef" -}}
{{- $image := .image }}
{{- if $image.digest }}
{{- if not (hasPrefix "sha256:" $image.digest) }}
{{- fail (printf "image digest %q must start with sha256:" $image.digest) }}
{{- end }}
{{- printf "%s@%s" $image.repository $image.digest }}
{{- else }}
{{- printf "%s:%s" $image.repository (required (printf "a tag or digest is required for image %s" $image.repository) .defaultTag) }}
{{- end }}
{{- end }}

{{- define "stroom-proxy.image" -}}
{{- include "stroom-proxy.imageRef" (dict "image" .Values.image "defaultTag" (include "stroom-proxy.imageTag" .)) }}
{{- end }}

{{/* Directories inside the proxy container. The data volume is mounted once
at volumeDir; the proxy creates data/, temp/ and logs/ inside it (fsGroup makes
it writable), which avoids kubelet-created, root-owned subPath directories. */}}
{{- define "stroom-proxy.home" -}}/stroom-proxy{{- end }}
{{- define "stroom-proxy.volumeDir" -}}/stroom-proxy/volume{{- end }}
{{- define "stroom-proxy.dfkDir" -}}/stroom-proxy/data_feed_identities{{- end }}
{{- define "stroom-proxy.tlsDir" -}}/stroom-proxy/tls{{- end }}
{{- define "stroom-proxy.keystore" -}}/stroom-proxy/tls/server.p12{{- end }}

{{/* Seconds the preStop hook sleeps, and the pod's termination grace period. */}}
{{- define "stroom-proxy.preStopSeconds" -}}
{{- add .Values.drain.deregistrationDelaySeconds .Values.drain.preStopExtraSeconds }}
{{- end }}
{{- define "stroom-proxy.terminationGraceSeconds" -}}
{{- add (include "stroom-proxy.preStopSeconds" . | int) .Values.drain.shutdownGracePeriodSeconds 30 }}
{{- end }}
