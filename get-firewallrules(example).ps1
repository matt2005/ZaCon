$rules = get-firewallrules
#$rules[0]
$rules | ?{ $_.localports -match 77}
($rules | ?{ $_.localports -match 77}).length
$rules.length
#$rules[0].Enabled = $false