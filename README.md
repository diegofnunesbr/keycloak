# keycloak

**Keycloak** (SSO) do homelab em `https://keycloak.diegofnunesbr.com`, com um
Postgres próprio. Mesmo papel do `sso.mercadoe.com` da empresa: os apps
não guardam usuário e senha, só confiam no Keycloak.

Na empresa, o ArgoCD chega no Keycloak passando pelo GitLab (ArgoCD →
Dex/GitLab → Keycloak `zerotrust` → Microsoft). Aqui não tem GitLab, então
o ArgoCD fala direto com o Keycloak.

## Pré-requisitos

- ArgoCD, Sealed Secrets, `ingress-nginx` e `cert-manager` instalados
  (repositórios de mesmo nome)
- DNS `keycloak.diegofnunesbr.com` apontando pro node (repositório `dns`)
- Contexto `k0s` no seu kubeconfig (ver README do repositório `argocd`,
  seção "Acessar o cluster de fora da VM"), pros scripts de senha

## Estrutura do repositório

```text
keycloak/
├── applications/
│   └── argocd.keycloak.yaml         # Application do Argo CD
├── k8s/
│   ├── keycloak.yaml                # Namespace, Postgres, Keycloak, Service, Ingress
│   ├── realm-homelab.yaml           # realm homelab (importado na primeira subida)
│   ├── keycloak-db.sealed.yaml      # senha do Postgres (aleatória, selada)
│   └── keycloak-admin.sealed.yaml   # usuário e senha do admin do Keycloak (selada)
├── change-user-password.sh          # senha do seu usuário no realm homelab
├── change-admin-password.sh         # senha do admin do Keycloak
└── README.md
```

## Instalar

```bash
git clone https://github.com/diegofnunesbr/keycloak.git
cd keycloak
kubectl --context=k0s apply -f applications/argocd.keycloak.yaml
```

A primeira subida do Keycloak leva uns 2 minutos (ele monta a
configuração e cria as tabelas no Postgres). Depois, defina a senha do
seu usuário, sem ela não dá pra entrar em nada:

```bash
./change-user-password.sh
```

## Realm `homelab`

`k8s/realm-homelab.yaml` é importado com `--import-realm` **só na
primeira subida** (se o realm já existe, o Keycloak ignora o arquivo).
Ele cria:

- usuário `diegofnunesbr` (sem senha; defina com `change-user-password.sh`)
- grupos `argocd-admins`, `jenkins-admins`, `grafana-admins` e
  `rundeck-admins`, com o seu usuário em todos
- cliente `argocd`: público, com PKCE (`S256`), então não tem segredo de
  cliente guardado em lugar nenhum. O token leva um campo `groups` com os
  grupos do usuário, que o ArgoCD usa pra dar permissão.

Mudanças depois disso são feitas no console de administração
(`https://keycloak.diegofnunesbr.com/admin`, realm `homelab`). Se quiser que
uma mudança sobreviva a uma reinstalação do zero, replique no JSON -
**exceto clientes confidenciais** (com segredo, como o `jenkins`, ver
seção abaixo), que não entram no JSON de propósito.

## Adicionar um cliente confidencial (app com segredo, tipo Jenkins)

Diferente do `argocd` (público, PKCE, sem segredo), a maioria dos apps
usa um client secret. Esse segredo não vai pro `realm-homelab.yaml` em texto
puro - cada app repositório guarda o dele, selado
(`secrets/<app>-oidc.sealed.yaml`, ver README do repositório do app).

Pra criar um cliente novo desses, rode direto no pod do Keycloak (troque
`<app>` e as URLs; `kubectl --context=k0s -n keycloak get secret
keycloak-admin` tem a senha do `admin`):

```bash
kubectl --context=k0s -n keycloak exec -it deploy/keycloak -- sh -c '
  /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user admin
  /opt/keycloak/bin/kcadm.sh create clients -r homelab -f - <<EOF
{
  "clientId": "<app>",
  "enabled": true,
  "publicClient": false,
  "standardFlowEnabled": true,
  "directAccessGrantsEnabled": false,
  "redirectUris": ["https://<app>.diegofnunesbr.com/<caminho-de-callback>"],
  "webOrigins": ["https://<app>.diegofnunesbr.com"],
  "attributes": {
    "post.logout.redirect.uris": "https://<app>.diegofnunesbr.com/*"
  },
  "protocolMappers": [{
    "name": "groups", "protocol": "openid-connect",
    "protocolMapper": "oidc-group-membership-mapper",
    "config": {
      "full.path": "false", "id.token.claim": "true",
      "access.token.claim": "true", "userinfo.token.claim": "true",
      "claim.name": "groups"
    }
  }]
}
EOF
  CID=$(/opt/keycloak/bin/kcadm.sh get clients -r homelab -q clientId=<app> --fields id --format csv --noquotes)
  /opt/keycloak/bin/kcadm.sh get clients/$CID/client-secret -r homelab --fields value --format csv --noquotes
'
```

O valor impresso no final é o segredo - selar ele como `clientSecret` no
repo do app (mesmo padrão do `secrets/jenkins-oidc.sealed.yaml`).
**`post.logout.redirect.uris` é fácil de esquecer** (não é o mesmo campo
de `redirectUris`) e sem ele o logout falha com "Invalid redirect uri".

## Senhas

| O quê | Onde fica | Como trocar |
|---|---|---|
| Seu usuário (`diegofnunesbr`, realm `homelab`) | só no banco do Keycloak | `./change-user-password.sh` |
| Admin do Keycloak (realm `master`) | `k8s/keycloak-admin.sealed.yaml` | `./change-admin-password.sh` (troca no Keycloak e sela de novo) |
| Postgres | `k8s/keycloak-db.sealed.yaml` | aleatória, não precisa trocar |

A senha inicial do admin é aleatória. Pra ver:

```bash
kubectl --context=k0s -n keycloak get secret keycloak-admin -o jsonpath='{.data.password}' | base64 -d; echo
```

O Keycloak marca esse admin como "temporário" (é o admin criado pelas
variáveis `KC_BOOTSTRAP_ADMIN_*`) e mostra um aviso no console. Funciona
normalmente; o aviso é só a recomendação de criar um admin permanente.

## Reinstalação do zero

O banco do Keycloak mora na PVC `postgres-data`. Com o cluster recriado,
ele sobe vazio: o realm `homelab` é importado de novo pelo JSON e o admin é
criado pelo Secret, mas a senha do seu usuário tem que ser definida de
novo (`change-user-password.sh`). Se a chave do Sealed Secrets também for
nova, os dois `*.sealed.yaml` precisam ser gerados de novo.
