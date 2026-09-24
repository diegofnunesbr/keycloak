#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

CTX="${KUBE_CONTEXT:-k0s}"
K="kubectl --context=$CTX -n keycloak"
SEALED=k8s/keycloak-admin.sealed.yaml
$K get deploy keycloak >/dev/null || { echo "Sem acesso ao Keycloak pelo contexto '$CTX' (ver README do repositório argocd, seção do kubeconfig)."; exit 1; }

read -rsp "Nova senha do admin do Keycloak: " PW; echo
read -rsp "Confirme a senha: " PW2; echo
[ -n "$PW" ] && [ "$PW" = "$PW2" ] || { echo "Senhas vazias ou diferentes."; exit 1; }

ADMIN_USER=$($K get secret keycloak-admin -o jsonpath='{.data.username}' | base64 -d)
OLD_PW=$($K get secret keycloak-admin -o jsonpath='{.data.password}' | base64 -d)

git pull --ff-only

printf '%s\n%s\n' "$OLD_PW" "$PW" | $K exec -i deploy/keycloak -- sh -c '
  IFS= read -r A; IFS= read -r P
  C=/tmp/kcadm-$$.config
  /opt/keycloak/bin/kcadm.sh config credentials --config "$C" --server http://localhost:8080 --realm master --user "'"$ADMIN_USER"'" --password "$A" >/dev/null
  /opt/keycloak/bin/kcadm.sh set-password --config "$C" -r master --username "'"$ADMIN_USER"'" --new-password "$P"
  S=$?; rm -f "$C"; exit $S'
unset OLD_PW

cat <<EOF | kubeseal --context "$CTX" --controller-name sealed-secrets --controller-namespace kube-system \
  --scope cluster-wide --format yaml > "$SEALED"
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-admin
  namespace: keycloak
type: Opaque
data:
  username: $(printf '%s' "$ADMIN_USER" | base64 -w0)
  password: $(printf '%s' "$PW" | base64 -w0)
EOF
unset PW PW2

git add "$SEALED"
git commit -m "rotate keycloak admin password"
git push
echo "Pronto. Login: $ADMIN_USER + senha nova em https://keycloak.diegofnunesbr.com/admin"
