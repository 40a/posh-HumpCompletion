function DebugMessage($message) {
    # $threadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId
    # $appDomainId = [AppDomain]::CurrentDomain.Id
    # [System.Diagnostics.Debug]::WriteLine("PoshHump: $threadId : $appDomainId :$message")
    [System.Diagnostics.Debug]::WriteLine("PoshHump: $message")
}

function GetCommandWithVerbAndHumpSuffix($commandName) {
    $separatorIndex = $commandName.IndexOf('-')
    if ($separatorIndex -ge 0){
        $verb = $commandName.SubString(0, $separatorIndex)
        $suffix = $commandName.SubString($separatorIndex+1)
        return [PSCustomObject] @{
            "Verb" = $verb
            "Suffix" = $suffix
            "SuffixHumpForm" = $suffix -creplace "[a-z]","" # case sensitive replace
            "Command" = $commandName 
        }   
    }    
}
function GetCommandsWithVerbAndHumpSuffix() {
    # TODO - add caching
    $commandsGroupedByVerb = Get-Command `
        | ForEach-Object { GetCommandWithVerbAndHumpSuffix $_.Name} `
        | Group-Object Verb
    $commands = @{}
    $commandsGroupedByVerb | ForEach-Object { $commands[$_.Name] = $_.Group | group-object SuffixHumpForm }
    return $commands
}
function GetWildcardSuffixForm($suffix){
    # create a wildcard form of a suffix. E.g. for "AzRGr" return "Az*R*Gr*"
    if ($suffix -eq $null -or $suffix.Length -eq 0){
        return "*"
    }
    $result = $suffix[0]
    for($i=1 ; $i -lt $suffix.Length ; $i++){
        if ([char]::IsUpper($suffix[$i])) {
            $result += "*"
        }
        $result += $suffix[$i]
    }
    $result += "*"
    return $result
}
$Powershell = $null
$Runspace = $null
function EnsureHumpCompletionCommandCache(){
    if ($global:HumpCompletionCommandCache -eq $null) {
        if ($script:runspace -eq $null) {
            DebugMessage -message "loading command cache"
            $global:HumpCompletionCommandCache = GetCommandsWithVerbAndHumpSuffix
        } else {
            DebugMessage -message "loading command cache - wait on async load"
            $foo = $script:Runspace.AsyncWaitHandle.WaitOne()
            $global:HumpCompletionCommandCache = $script:powershell.EndInvoke($script:iar).result
            $script:Powershell.Dispose()
            $script:Runspace.Close()
            $script:Runspace = $null            
            DebugMessage -message "loading command cache - async load commplete $($global:HumpCompletionCommandCache.Count)"
        }
    }
}
function LoadHumpCompletionCommandCacheAsync(){
    DebugMessage -message "LoadHumpCompletionCommandCacheAsync"
    if ($script:Runspace -eq $null) {
        DebugMessage -message "LoadHumpCompletionCommandCacheAsync - starting..."
        $script:Runspace = [RunspaceFactory]::CreateRunspace()
        $script:Runspace.Open()
        # Set variable to prevent installation of the TabExpansion function in the created runspace
        # Otherwise we end up recursively spinning up runspaces to load the commands!
        $script:Runspace.SessionStateProxy.SetVariable('poshhumpSkipTabCompletionInstall',$true)

        $script:Powershell = [PowerShell]::Create()
        $script:Powershell.Runspace = $script:Runspace

        $scriptBlock = {
            $result = GetCommandsWithVerbAndHumpSuffix
            @{ "result" = $result} # work around group enumeration as it loses the grouping!
        }
        $script:Powershell.AddScript($scriptBlock) | out-null
        
        $script:iar = $script:PowerShell.BeginInvoke()
    }
}
function PoshHumpTabExpansion2($ast){
    
    $result = $null;
    DebugMessage "In PoshHumpTabExpansion2"
    $statements = $ast.EndBlock.Statements
    $command = $statements.PipelineElements[$statements.PipelineElements.Count-1]
    $commandName = $command.GetCommandName()
    $commandElements = $command.CommandElements

    DebugMessage "$commandName"

    if ( $commandElements.Count -eq 1) {         
        ## if 1 command element then just the command (rather than parameters)
        DebugMessage "single cmd element: $commandName"      
        EnsureHumpCompletionCommandCache
        
        $commandInfo = GetCommandWithVerbAndHumpSuffix $commandName
        $verb = $commandInfo.Verb
        $suffix= $commandInfo.Suffix
        $suffixWildcardForm = GetWildcardSuffixForm $suffix 
        $wildcardForm = "$verb-$suffixWildcardForm"
        $commands = $global:HumpCompletionCommandCache
        if ($commands[$verb] -ne $null) {
            $completionMatches = $commands[$verb] `
                | Where-Object { 
                    # $_.Name is suffix hump form
                    # Match on hump form of completion word
                    $_.Name.StartsWith($commandInfo.SuffixHumpForm)
                } `
                | Select-Object -ExpandProperty Group `
                | Select-Object -ExpandProperty Command `
                | Where-Object { $_ -like $wildcardForm } `
                | Sort-Object
                
            $result = [PSCustomObject]@{
                ReplacementIndex = $command.Extent.StartOffset;
                ReplacementLength = $command.Extent.EndOffset - $command.Extent.StartOffset;
                CompletionMatches = $completionMatches
            };
        }
    } elseif ($commandElements.Count -gt 1 -and $commandElements[$commandElements.Count-1].GetType().Name -eq "CommandParameterAst"){
        
        $command = Get-Command  $commandName -ShowCommandInfo
        if ($command.CommandType -eq "Alias") {
            $command = Get-Command $command.Definition -ShowCommandInfo
        }
        
        # complete the parameter!
        $parameterElement = $commandElements[$commandElements.Count -1]
        $parameterName = $parameterElement.ParameterName 
        $wildcardForm = GetWildcardSuffixForm $parameterName
        DebugMessage "multi cmd element. Parameter: '$parameterName', wildcardForm: $wildcardForm"      
        # TODO - look at whether we can determine the parameter set to be smarter about the parameters we complete
        $completionMatches = $command.ParameterSets `
                                | Select-Object -ExpandProperty Parameters `
                                | Select-Object -ExpandProperty Name -Unique `
                                | Where-Object { $_ -clike $wildcardForm } `
                                | Sort-Object

        $result = [PSCustomObject]@{
            ReplacementIndex = $parameterElement.Extent.StartOffset + 1; # +1 for the '-'
            ReplacementLength = $parameterElement.Extent.EndOffset - $parameterElement.Extent.StartOffset - 1;
            CompletionMatches = $completionMatches
        };
    }
    return $result
}

function Clear-HumpCompletionCommandCache() {
    [Cmdletbinding()]
    param()

    DebugMessage -message "PoshHumpTabExpansion:clearing command cache"
    $global:HumpCompletionCommandCache = $null
}
function Stop-HumpCompletion(){
    [Cmdletbinding()]
    param()

    $global:HumpCompletionEnabled = $false
}
function Start-HumpCompletion(){
    [Cmdletbinding()]
    param()
    
    $global:HumpCompletionEnabled = $true
}

# install the handler!
DebugMessage -message "Installing: Test PoshHumpTabExpansion2Backup function"
if ($poshhumpSkipTabCompletionInstall){
    DebugMessage -message "Skipping tab expansion installation"
} else {
    if (-not (Test-Path Function:\PoshHumpTabExpansion2Backup)) {

        if (Test-Path Function:\TabExpansion2) {
            DebugMessage -message "Installing: Backup TabExpansion2 function"
            Rename-Item Function:\TabExpansion2 PoshHumpTabExpansion2Backup
        }
        
        function TabExpansion2(){
            <# Options include:
                RelativeFilePaths - [bool]
                    Always resolve file paths using Resolve-Path -Relative.
                    The default is to use some heuristics to guess if relative or absolute is better.

            To customize your own custom options, pass a hashtable to CompleteInput, e.g.
                    return [System.Management.Automation.CommandCompletion]::CompleteInput($inputScript, $cursorColumn,
                        @{ RelativeFilePaths=$false } 
            #>

            [CmdletBinding(DefaultParameterSetName = 'ScriptInputSet')]
            Param(
                [Parameter(ParameterSetName = 'ScriptInputSet', Mandatory = $true, Position = 0)]
                [string] $inputScript,
                
                [Parameter(ParameterSetName = 'ScriptInputSet', Mandatory = $true, Position = 1)]
                [int] $cursorColumn,

                [Parameter(ParameterSetName = 'AstInputSet', Mandatory = $true, Position = 0)]
                [System.Management.Automation.Language.Ast] $ast,

                [Parameter(ParameterSetName = 'AstInputSet', Mandatory = $true, Position = 1)]
                [System.Management.Automation.Language.Token[]] $tokens,

                [Parameter(ParameterSetName = 'AstInputSet', Mandatory = $true, Position = 2)]
                [System.Management.Automation.Language.IScriptPosition] $positionOfCursor,
                
                [Parameter(ParameterSetName = 'ScriptInputSet', Position = 2)]
                [Parameter(ParameterSetName = 'AstInputSet', Position = 3)]
                [Hashtable] $options = $null
            )
            End
            {
                if ($psCmdlet.ParameterSetName -eq 'ScriptInputSet')
                {
                    $results = [System.Management.Automation.CommandCompletion]::CompleteInput(
                        <#inputScript#>  $inputScript,
                        <#cursorColumn#> $cursorColumn,
                        <#options#>      $options)
                }
                else
                {
                    $results = [System.Management.Automation.CommandCompletion]::CompleteInput(
                        <#ast#>              $ast,
                        <#tokens#>           $tokens,
                        <#positionOfCursor#> $positionOfCursor,
                        <#options#>          $options)
                }
                
                if ($psCmdlet.ParameterSetName -eq 'ScriptInputSet')
                {
                    $ast = [System.Management.Automation.Language.Parser]::ParseInput($inputScript, [ref]$tokens, [ref]$null)
                }
                else
                {
                    $cursorColumn = $positionOfCursor.Offset
                }

                
                $poshHumpResult = PoshHumpTabExpansion2 $ast
                if ($poshHumpResult -ne $null){
                    $results.ReplacementIndex = $poshHumpResult.ReplacementIndex
                    $results.ReplacementLength = $poshHumpResult.ReplacementLength
                    
                    # From TabExpansionPlusPlus: Workaround where PowerShell returns a readonly collection that we need to add to.
                    if ($results.CompletionMatches.IsReadOnly) {
                        $collection = new-object System.Collections.ObjectModel.Collection[System.Management.Automation.CompletionResult]
                        $results.GetType().GetProperty('CompletionMatches').SetValue($results, $collection)
                    }
                    
                    $results.CompletionMatches.Clear() # TODO - look at inserting at front instead of clearing as this removes standard completion! Augment vs override
                    $poshHumpResult.CompletionMatches | % { $results.CompletionMatches.Add($_)}
                }
                
                return $results
            }
        }
        LoadHumpCompletionCommandCacheAsync
    }
}
$global:HumpCompletionEnabled = $true