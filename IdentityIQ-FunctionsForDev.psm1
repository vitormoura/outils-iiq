
function Export-IIQRuleFiles {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $PathJavaFiles,

        [ValidateNotNullOrEmpty()]
        [string] $OutputDir = $null
    )
    
    $liste_rules = @();
    $liste_files = (Get-ChildItem $PathJavaFiles);

    if(-not $liste_files -or $liste_files.Length -eq 0) {
        Write-Error "No java files found at $($PathJavaFiles)";
        exit 1
    }
	
	Write-Debug "$($liste_files.Count) files(s) found";
	Write-Debug $liste_files.ToString();
       

    if( -not (Test-Path $OutputDir) ) {
        Write-Error "Invalid output dir: $($OutputDir)"
        exit 1
    }

    foreach ($file in ( $liste_files | Select -ExpandProperty FullName)) {

        $lignes = Get-Content $file | Select-String -AllMatches -Pattern 'class[.|\s]([a-zA-Z0-9_]{0,})[\s]{0,}(extends[\s]{1,}([a-zA-Z0-9_]{1,}))?|\/\/[\s]?[Rr]ule[\s]{1,}[Nn]ame:[\s]?([\sa-zA-Z\-0-9\.]{1,})' | Select -ExpandProperty Matches;
        $metadata = $lignes | Select -ExpandProperty Groups | select -ExpandProperty $_.Captures | Where-Object { $_.Value -and -not $_.Value.Contains(' ') } | Select -ExpandProperty Value
        $rule = @{ File = $file; Type = ""; Name = $metadata[0];  Class = $metadata[1]; Extends = $null };
        $rule.Type = $metadata[0] | Select-String -AllMatches -Pattern "RQ-Rule\-([a-zA-Z]{1,})\-" | ForEach-Object { return $_.Matches.Groups[1].Value }

        If (-not $metadata[2].Contains("class")) { 
            $rule.Extends = $metadata[2] ;
        } 
    
        Write-Output $metadata | fl;

        $liste_rules += $rule;
				
    }
	
	Write-Debug "$($liste_rules.Count) rule(s) found: $($liste_rules | Select Name)";

    foreach( $rule in $liste_rules ) {
        $template_name = [System.IO.Path]::Combine($PSScriptRoot,"Template-Rule-$($rule.Type).xml");
        
        Write-Debug "generating xml rule from java class $($rule.Class)..."
    
        if(Test-Path $template_name) {
            $xml = [xml](Get-Content $template_name -Encoding UTF8);
            $xml.SelectSingleNode("//Rule/@name").Value = $rule.Name;
                        
            if($rule.Extends -ne $null) {
                $parent_rule = $liste_rules | Where-Object Class -eq $rule.Extends;

                Write-Debug "adding library reference: $($parent_rule.Name) ($($rule.Extends) class)"
                
                $xml.SelectSingleNode("//Rule/ReferencedRules/Reference/@name").Value = $parent_rule.Name;

            } else {

                Write-Debug "no library reference found";

                $nodeToDelete = $xml.SelectSingleNode("//Rule/ReferencedRules");
                $nodeToDelete.ParentNode.RemoveChild($nodeToDelete) | Out-Null;
            }
                        
            $cdataContent = [System.Text.StringBuilder]::New();
                        
            foreach($line in (Get-IIQFormattedCodeFromJavaFile -Path $rule.File )) {
                $cdataContent.AppendLine($line) | Out-Null;
            }

            Write-Debug "$($cdataContent.Length) bytes of code";

            $xml.SelectSingleNode("//Rule/Source").AppendChild($xml.CreateCDataSection($cdataContent.ToString())) | Out-Null;
            $xml.Save([System.IO.Path]::Combine($OutputDir, "$($rule.Name).xml")) | Out-Null;
			
			Write-Debug "$($rule.Name).xml succesfully created ";
            Write-Debug ""

        } else {
            Write-Warning "no template for '$($rule.Type)' xml files"
        }

    }

    Write-Output "$($liste_rules.Count) file(s) generated at $($OutputDir)"

}


function Get-IIQFormattedCodeFromJavaFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path        
    )

    # balises à chercher dans les fichiers java
    $START_FUNCTIONS = '// RULE FUNCTIONS'
    $END_FUNCTIONS = '// END FUNCTIONS'
    $START_BLOCK = '// RULE BODY'
    $END_BLOCK = '// END BODY'
    $LINES_TO_IGNORE = @('package rules', '@SuppressWarnings')

    Write-Debug "extracting code from java file: $([System.IO.Path]::GetFileName($Path))"

    $file_contents = $null;
    $func_tab_count = $null;
    $body_tab_count = $null;
    $fichier_cible = $null;
    $id_rule = $null;
    
    $within_imports = $true
    $within_body = $false;    
    $within_functions = $false;
    
    $body = @();
    $imports = @();
    $functions = @();

    # Chaque ligne
    foreach($line in Get-Content $Path -Encoding UTF8) {

        # Nom fichier généré
        if($line.ToLower().Contains("// rule name")) {
            $fichier_cible = $line.Substring($line.IndexOf(':') + 1).Trim();
            continue;
        }

        # Identifiant rule
        if($line.ToLower().Contains("// rule id")) {
            $id_rule = $line.Substring($line.IndexOf(':') + 1).Trim();
            continue;
        }

        # Block imports
           
        if($line.Contains("class ")) {
            $within_imports = $false;
        }

        if($within_imports) {

            # ignore quelque imports ou d'autre directives
            if(($LINES_TO_IGNORE | Where-Object { $line.TrimStart().StartsWith($_) })) {
                continue;
            }

            $imports += $line
            continue;
        }

        # Fin block imports
        
        # Block functions/methods

        if($line.Contains($END_FUNCTIONS)) {
            $within_functions = $false;
            continue;
        }
                
        if($line.Contains($START_FUNCTIONS) -or $within_functions) {

            if($func_tab_count -eq $null) { # Si nule, c'est la première ligne du bloque, il faut calculer le nombre de tabs
                $func_tab_count = $line.IndexOf($START_FUNCTIONS[0]);
            }

            if($line.Length -lt $func_tab_count) {
                $functions += $line;
            } else {
                $functions += $line.Substring($func_tab_count); # enlève les tabs
            }

            
            $within_functions = $true;
            continue;
        }

        # Fin block functions/methods

        # Block body

        if($line.Contains($END_BLOCK)) {
            $within_body = $false;
            continue
        }
        
        if($line.Contains($START_BLOCK) -or $within_body) {
            if($body_tab_count -eq $null) {
                $body_tab_count = $line.IndexOf($START_BLOCK[0]);
            }
            
            if($line.Length -lt $body_tab_count) {
                $body += $line;
            }
            else {
                $body += $line.Substring($body_tab_count);
            }

            $within_body = $true;
            continue;
        }

        # Fin block body
    }


    if($fichier_cible -ne $null) {
                
		$file_contents = @();
                  
        # Entête fichier
        $file_contents += $([System.Environment]::NewLine);
        $file_contents += "// Fichier rule IdentityIQ: $([System.IO.Path]::GetFileName($fichier_cible))";
        $file_contents += "// Généré par $($Env:UserName) à $((Get-Date))";
        $file_contents += "// Fichier d'origine $([System.IO.Path]::GetFileName($file))$([System.Environment]::NewLine)";
                
        # Contenu
        $file_contents += $imports;
        $file_contents += $functions;
        $file_contents += $body;

        # Hash contenu du fichier, va nous permettre de vérifier quel version est présentement au serveur IdentityIQ
        $file_contents += $([System.Environment]::NewLine);
    }

    return $file_contents -join [System.Environment]::NewLine;
}
