{{- define "paperless-pdf-unlocker.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end -}}
