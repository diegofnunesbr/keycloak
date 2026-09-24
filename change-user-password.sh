#!/bin/bash
set -euo pipefail

CTX="${KUBE_CONTEXT:-k0s}"
K="kubectl --context=$CTX -n keycloak"
REALM="${REALM:-home}"
$K get deploy keycloak >/dev/null || { echo "Sem acesso ao Keycloak pelo contexto '$CTX' (ver README do repositório argocd, seção do kubeconfig)."; exit 1; }

read -rp "Usuário do realm $REALM [diegofnunesbr]: " USERNAME
USERNAME="${USERNAME:-diegofnunesbr}"
[[ "$USERNAME" =~ ^[a-zA-Z0-9._@-]+$ && "$REALM" =~ ^[a-zA-Z0-9._-]+$ ]] || { echo "Usuário ou realm com caracteres inválidos."; exit 1; }
read -rsp "Nova senha: " PW; echo
read -rsp "Confirme a senha: " PW2; echo
[ -n "$PW" ] && [ "$PW" = "$PW2" ] || { echo "Senhas vazias ou diferentes."; exit 1; }

ADMIN_USER=$($K get secret keycloak-admin -o jsonpath='{.data.username}' | base64 -d)
ADMIN_PW=$($K get secret keycloak-admin -o jsonpath='{.data.password}' | base64 -d)

printf '%s\n%s\n' "$ADMIN_PW" "$PW" | $K exec -i deploy/keycloak -- sh -c '
  IFS= read -r A; IFS= read -r P
  C=/tmp/kcadm-$$.config
  /opt/keycloak/bin/kcadm.sh config credentials --config "$C" --server http://localhost:8080 --realm master --user "'"$ADMIN_USER"'" --password "$A" >/dev/null
  /opt/keycloak/bin/kcadm.sh set-password --config "$C" -r "'"$REALM"'" --username "'"$USERNAME"'" --new-password "$P"
  S=$?; rm -f "$C"; exit $S'
unset ADMIN_PW PW PW2
echo "Pronto. Senha de $USERNAME trocada no realm $REALM."
