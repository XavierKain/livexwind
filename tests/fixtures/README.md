Réponses réelles enregistrées le 2026-09-01, qui servent de garde-fou aux parseurs :
si une source change son format, les tests cassent avant que l'app n'affiche
silencieusement des données périmées.

`balisemeteo_64_masked.html` est **reconstruit** à partir de la page réelle en
réinjectant le balisage `!!! WARNING !!!` du site. La capture directe n'a pas
fonctionné : le masquage de balisemeteo est intermittent et n'est pas uniquement
lié à l'absence de session — d'où l'amorçage systématique côté client.

Pour les régénérer : `python3 tests/record_fixtures.py`
