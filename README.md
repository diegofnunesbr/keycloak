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
│   ├── realm-home.yaml           # realm home (importado na primeira subida)
│   ├── keycloak-db.sealed.yaml      # senha do Postgres (aleatória, selada)
│   └── keycloak-admin.sealed.yaml   # usuário e senha do admin do Keycloak (selada)
├── change-user-password.sh          # senha do seu usuário no realm home
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

## Realm `home`

`k8s/realm-home.yaml` é importado com `--import-realm` **só na
primeira subida** (se o realm já existe, o Keycloak ignora o arquivo).
Ele cria:

- usuário `diegofnunesbr` (sem senha; defina com `change-user-password.sh`)
- grupo `argocd-admins`, com o seu usuário dentro
- cliente `argocd`: público, com PKCE (`S256`), então não tem segredo de
  cliente guardado em lugar nenhum. O token leva um campo `groups` com os
  grupos do usuário, que o ArgoCD usa pra dar permissão.

Mudanças depois disso são feitas no console de administração
(`https://keycloak.diegofnunesbr.com/admin`, realm `home`). Se quiser que
uma mudança sobreviva a uma reinstalação do zero, replique no JSON.

## Senhas

| O quê | Onde fica | Como trocar |
|---|---|---|
| Seu usuário (`diegofnunesbr`, realm `home`) | só no banco do Keycloak | `./change-user-password.sh` |
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
ele sobe vazio: o realm `home` é importado de novo pelo JSON e o admin é
criado pelo Secret, mas a senha do seu usuário tem que ser definida de
novo (`change-user-password.sh`). Se a chave do Sealed Secrets também for
nova, os dois `*.sealed.yaml` precisam ser gerados de novo.
