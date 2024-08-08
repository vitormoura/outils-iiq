
function Import-IIQRuleFile {
    [CmdletBinding()]
    param(
        [Alias("FullName")]
        [Parameter(Mandatory, ValueFromPipeline = $true, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string] $File,
        
        [ValidateNotNullOrEmpty()]
        [string] $OutFile
    )

    Process {
        
        Write-Debug "reading $($File)";

        if(-not(Test-Path $File)) {
            Write-Error "invalid file path: $($Error[0])";
            exit 1;
        }

        $content = Get-Content $File -Raw -Encoding UTF8;
        $xmlDoc = [xml]($content);
        $rule = [PSCustomObject]@{
            Name        = ""
            Type        = ""
            Source      = ""
            Description = ""
            References  = @()
            ReturnType = ""
        };

        $rule.Name = $xmlDoc.SelectSingleNode("//Rule/@name").Value;
        $typeNode = $xmlDoc.SelectSingleNode("//Rule/@type");
        $descNode = $xmlDoc.SelectSingleNode("//Rule/Description");
        $returnTypeNode = $xmlDoc.SelectSingleNode("//Rule/Signature/@returnType");
            
        if ($descNode) {
            Write-Debug "reading rule description"
            $rule.Description = $descNode.InnerText;
        }

        if ($typeNode) {
            Write-Debug "reading rule type"
            $rule.Type = $typeNode.Value;
        }

        if($returnTypeNode) {
            Write-Debug "reading rule return type"
            $rule.ReturnType = $returnTypeNode.Value;
        }
            
        Write-Debug "rule name: $($rule.Name)";

        $refsNode = $xmlDoc.SelectSingleNode("//Rule/ReferencedRules");

        if ($refsNode) {
            Write-Debug "reading references rules";
            $rule.References = $refsNode.SelectNodes("descendant::Reference/@name") | Select-Object -ExpandProperty Value;

            Write-Debug $rule.References;
        }
        else {
            Write-Debug "no referenced rules";
        }

        $padding = "   ";
        $lineNumber = 0;
        $ruleIsLibrary = -not $rule.Type -or ($rule.Type -eq "Library");
        $rule.Source = $xmlDoc.SelectSingleNode("//Rule/Source").InnerText;
        $javaSource = @();
        $javaImports = @("import sailpoint.api.SailPointContext;");

        $javaSource += "";
        $javaSource += "public class $($rule.Name -replace '[-\s]', '') { ";
        
        # rajoute des variables globales selon le type de règle

        $javaSource += $padding + "SailpointContext context;";

        if(-not $ruleIsLibrary) {
            $javaSource += "";
            $javaSource += $padding + "public $(if($rule.ReturnType) { $rule.ReturnType } else { "void" }) executeRule() {";
            $javaSource += "";
        }

        $javaSource += "";
        
        foreach ( $line in $rule.Source -split "\n" ) {
            $lineNumber++;

            if ($line -match "[\s]{0,}import[\s]{1,}") {
                $javaImports += $line.Trim();
                continue;
            }

            #if(-not $line.Trim()) {
            #    continue;
            #}

            $javaSource += $padding + $line;
        }

        if(-not $ruleIsLibrary) {
            $javaSource += "}"    
        }

        $javaSource += "}"

        $javaSource = $javaImports + $javaSource;

        Write-Debug "java file content created: $($javaSource.Count) lines";
        Write-Debug ""

        $javaSource = $javaSource -join [System.Environment]::NewLine;

        if($OutFile) {
            $javaSource | Out-File -FilePath $OutFile -Encoding utf8;

            return $OutFile;

        } else {
            return $javaSource;
        }
    }
}

function Format-IIQJavaSourceFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Path        
    )

    if($null -eq (Get-Command ".\scripts\node_modules\.bin\prettier.ps1" -ErrorAction SilentlyContinue)) {
        Write-Error "Unable to find the prettier tool. Try again after install it using: npm install prettier-plugin-java --save-dev";
        exit 1;
    }

    if(-not (Test-Path $Path)) {
        Write-Error "Invalid input path";
        exit 1;
    }

    .\scripts\node_modules\.bin\prettier.ps1 $Path;
}

function Export-IIQRuleFiles {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $PathJavaFiles,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $OutputDir
    )
	
    Write-Debug ""
    Write-Debug "GÉNÉRATEUR FICHIERS XML IDENTITY IQ (RULES)" 
    Write-Debug "-------------------------------------------"
    Write-Debug ""
	
    # Obtient les métadonnées du projet depuis un fichier xml
	
    Write-Debug "fichier de métadonnées de projet: iiq-project.xml";
    Write-Debug ""
		
    $project_name = Select-Xml -Path  .\iiq-project.xml -XPath //iiq-project/name | Select-Object -ExpandProperty Node | Select-Object -ExpandProperty '#text';

    if ( -not $project_name ) {
        Write-Error "No projet name found";
        exit 1;
    }
    	
    $liste_rules = @();
    $liste_files = (Get-ChildItem $PathJavaFiles -Recurse | Select-Object -ExpandProperty FullName) ;

    if (-not $liste_files -or $liste_files.Length -eq 0) {
        Write-Error "Aucun fichier java trouvé dans le répertoire $($PathJavaFiles)";
        exit 1;
    }
	
    Write-Debug "$($liste_files.Count) fichier(s) retrouvés";
    Write-Debug ""
	
    if ( -not (Test-Path $OutputDir) ) {
        Write-Error "Répertoire invalide: $($OutputDir)";
        exit 1;
    }
    	
    if (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
        Write-Debug "Transforme chemin répertoire relatif vers complèt (fullname)";

        $OutputDir = ([System.IO.FileInfo]::new([System.IO.Path]::Combine($pwd.Path, $OutputDir)).FullName);

        Write-Debug $OutputDir;
    }

    Write-Debug "";

    # Prepare une liste avec les métadonnées de nos rules
    $liste_rules = $liste_files | Get-IIQRuleInfoFromJavaFile -Project $project_name;
    
    # Vérifie des doublons
    $duplicates = $liste_rules | Select-Object @{Label = "Name"; Expression = { $_.Name } } | Select-Object -ExpandProperty Name | Group-Object | Where-Object Count -gt 1;
    
    if ($duplicates.Count -gt 1) {
        Write-Debug "$($duplicates.Count-1) rules ont le même nom: ";
        $duplicates.Values.ForEach({ Write-Debug $_; });
        
        Write-Error ("Le processus a été annulé. Il y a des rules avec le même nom: ", ($duplicates.Values | Format-List | Out-String ) -join " : ");

        exit 1;
    }
    
    # Crée les fichiers XML pour chaque rule identifié
    foreach ( $rule in $liste_rules ) {
        $template_name = [System.IO.Path]::Combine($PSScriptRoot, "Template-Rule-$($rule.Type).xml");
        
        Write-Debug "";
        Write-Debug "traitement génération fichier xml pour la classe java $($rule.Package).$($rule.Class)...";
    
        if (Test-Path $template_name) {
            $xml = [xml](Get-Content $template_name -Encoding UTF8);
            $xml.SelectSingleNode("//Rule/@name").Value = $rule.Name;

            if ( $rule.Id ) {
                $idAttrib = $xml.CreateAttribute("id");
                $idAttrib.Value = $rule.Id;

                $xml.DocumentElement.SetAttributeNode($idAttrib) | Out-Null;
            }
            
            $parent_rule = $liste_rules | Where-Object Class -eq $rule.Extends;    
            
            if ($rule.Description) {
                $descEl = $xml.CreateElement("Description");
                $descEl.InnerText = $rule.Description;
                $xml.DocumentElement.AppendChild($descEl) | Out-Null;
            }

            if ($parent_rule.Name) {
                Write-Debug "rajoute une référence à la librairie $($parent_rule.Name) ($($rule.Extends) class)";
                
                $xml.SelectSingleNode("//Rule/ReferencedRules/Reference/@name").Value = $parent_rule.Name;

            }
            else {

                Write-Debug "la classe courante n'hérite pas d'aucune autre classe";

                $nodeToDelete = $xml.SelectSingleNode("//Rule/ReferencedRules");
                $nodeToDelete.ParentNode.RemoveChild($nodeToDelete) | Out-Null;
            }
                        
            $cdataContent = [System.Text.StringBuilder]::New();
                        
            foreach ($line in (Get-IIQFormattedCodeFromJavaFile -Path $rule.File )) {
                $cdataContent.AppendLine($line) | Out-Null;
            }

            Write-Debug "$($cdataContent.Length) bytes de code";

            $outputFileName = (Join-Path -Path $OutputDir -ChildPath "$($rule.Name).xml");
            $xml.SelectSingleNode("//Rule/Source").AppendChild($xml.CreateCDataSection($cdataContent.ToString())) | Out-Null;
            $xml.Save($outputFileName) | Out-Null;
									
            Write-Debug "$($rule.Name).xml créé avec succès ";
            Write-Debug "";

        }
        else {
            Write-Warning "aucun gabarit (template) trouvé pour transformer les rules de type '$($rule.Type)'"
        }
    }
	
    Write-Debug "$($liste_rules.Count) fichier(s) créés dans le répertoire $($OutputDir)";
    Write-Debug "";
		
    Convert-IIQRuleFileEncoding -Path $OutputDir | Out-Null;
	    	
    Write-Debug ""
    Write-Debug "-------------------------------------------"
    Write-Debug "TRAITEMENT TERMINÉ :)"
	
    return Get-ChildItem temp -Filter "*.xml"
}

function Convert-IIQRuleFileEncoding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path	
    )

    $Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($False);

    Write-Debug "transforme fichiers dans $($OutputDir) en fichiers UTF-8 (Without BOM)";
	
    $files = Get-ChildItem -Filter *.xml -Path $Path;

    foreach ( $xmlFile in $files ) {
        $lines = Get-Content -Path $xmlFile.FullName;
        [System.IO.File]::WriteAllLines($xmlFile.FullName, $lines, $Utf8NoBomEncoding);
		
        Write-Debug "- fichier $($xmlFile.Name) OK"
    }

    return $files;
}

function Get-IIQRuleInfoFromJavaFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [ValidateNotNullOrEmpty()]
        [string] $Project
    )
    
    Process {
                
        $rule = [PSCustomObject]@{
            File        = $Path
            Type        = "" 
            Name        = "" 
            Class       = $null
            Extends     = $null
            Id          = $null 
            Description = ""
            Package     = $null 
        };
    
        :outer
            
        foreach ($line in Get-Content $Path) {
    
            switch -Regex ($line) {
                "class[\s]{1,}([a-zA-Z0-9_]{0,})[\s]{0,}" {
                    # Rule Class et Extends

                    $indexClass = $_.IndexOf("class") + "class".Length + 1;
                    $indexExtends = $_.IndexOf("extends");
            
                    if ($indexExtends -ge 0) {
                        $rule.Class = $_.Substring($indexClass, $indexExtends - $indexClass).Trim();

                        $indexExtends = $indexExtends + "extends".Length + 1;
                        $rule.Extends = $_.Substring($indexExtends).Replace("{", "").Trim();
                    }
                    else {
                        $rule.Class = $_.Substring($indexClass).Replace('{', "").Trim();
                    }

                    Break outer;
                }
                "[\s]{0,}/{2,}[\s]{1,}[R|r]ule[\s]{1,}[iI][dD][\s]{0,}:[\s]{0,}[a-zA-Z0-9\s]{1,}" {
                    # Rule ID
                    $rule.Id = Get-IIQValueFromTextLine $_;
                    Break;
                }
                "[\s]{0,}/{2,}[\s]{1,}[R|r]ule[\s]{1,}[Nn]ame[\s]{0,}:[\s]{0,}[a-zA-Z0-9\s]{1,}" {
                    # Rule Name
                    $rule.Name = Get-IIQValueFromTextLine $_;
                    Break;
                }
                "[\s]{0,}/{2,}[\s]{1,}[R|r]ule[\s]{1,}[Tt]ype[\s]{0,}:[\s]{0,}[a-zA-Z0-9]{3,}" {
                    # Rule Type
                    $rule.Type = Get-IIQValueFromTextLine $_;
                    Break;
                }
                "[\s]{0,}/{2,}[\s]{1,}[R|r]ule[\s]{1,}[Dd]esc(ription)?[\s]{0,}:[\s]{0,}[a-zA-Z0-9\s]{1,}" {
                    # Description
                    $rule.Description = Get-IIQValueFromTextLine $_;
                    Break;
                }
                "^[\s]?package[\s]{1,}[a-zA-Z0-9_\.]{1,}[\s]?" {
                    $rule.Package = $_.Trim().Replace("package", "").Trim().replace(";", "");
                    Break;
                }
            }
        }

        if (-not $rule.Type) {
            $rule.Type = $rule.Class;
        }

        if (-not $rule.Name) {
            $rule.Name = "RQ-Rule-$($rule.Class)";

            if ($Project) {
                $rule.Name += "-$($Project)";
            }
        }
                        
        return $rule;
    }   
}

function Get-IIQFormattedCodeFromJavaFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,
                        
        [Microsoft.PowerShell.Commands.FileSystemCmdletProviderEncoding]$Encoding = [Microsoft.PowerShell.Commands.FileSystemCmdletProviderEncoding]::UTF8
    )

    # balises à chercher dans les fichiers java
    $START_FUNCTIONS = '// RULE FUNCTIONS'
    $END_FUNCTIONS = '// END FUNCTIONS'
    $START_BLOCK = '// RULE BODY'
    $END_BLOCK = '// END BODY'
    $LINES_TO_IGNORE = @('package rules', '@SuppressWarnings', "/**", "*", "*/")

    Write-Debug "analyse du code depuis le fichier java: $([System.IO.Path]::GetFileName($Path))"

    $file_contents = $null;
    $func_tab_count = $null;
    $body_tab_count = $null;
            
    $within_imports = $true
    $within_body = $false;    
    $within_functions = $false;
    
    $body = @();
    $imports = @();
    $functions = @();

    # Chaque ligne
    foreach ($line in Get-Content $Path -Encoding $Encoding) {
                
        # Block imports
           
        if ($line.Contains("class ")) {
            $within_imports = $false;
        }

        if ($within_imports) {

            # ignore quelque imports ou d'autre directives
            if (($LINES_TO_IGNORE | Where-Object { $line.TrimStart().StartsWith($_) })) {
                continue;
            }

            $imports += $line
            continue;
        }

        # Fin block imports
        
        # Block functions/methods

        if ($line.Contains($END_FUNCTIONS)) {
            $within_functions = $false;
            continue;
        }
                
        if ($line.Contains($START_FUNCTIONS) -or $within_functions) {

            if ($null -eq $func_tab_count) {
                # Si nule, c'est la première ligne du bloque, il faut calculer le nombre de tabs
                $func_tab_count = $line.IndexOf($START_FUNCTIONS[0]);
            }

            if ($line.Length -lt $func_tab_count) {
                $functions += $line;
            }
            else {
                $functions += $line.Substring($func_tab_count); # enlève les tabs
            }

            
            $within_functions = $true;
            continue;
        }

        # Fin block functions/methods

        # Block body

        if ($line.Contains($END_BLOCK)) {
            $within_body = $false;
            continue
        }
        
        if ($line.Contains($START_BLOCK) -or $within_body) {
            if ($null -eq $body_tab_count) {
                $body_tab_count = $line.IndexOf($START_BLOCK[0]);
            }
            
            if ($line.Length -lt $body_tab_count) {
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
         
    $newLine = $([System.Environment]::NewLine);
    $file_contents = @();

    # Entête fichier
    $file_contents += $newLine;
    $file_contents += "// Fichier rule IdentityIQ généré par $($Env:UserName) à $((Get-Date))";
                            
    # Contenu
    $file_contents += $imports;
    $file_contents += $functions;
    $file_contents += $body;
    $file_contents += $newLine;

    return $file_contents -join $newLine;
}

function Get-IIQValueFromTextLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Line,

        [ValidateNotNullOrEmpty()]
        [string] $Separator = ':'
    )

    Process {
        return $Line.Substring($Line.IndexOf($Separator) + 1).Trim();
    }
}
