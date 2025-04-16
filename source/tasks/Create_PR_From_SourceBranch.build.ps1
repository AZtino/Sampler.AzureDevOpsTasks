<#
    .SYNOPSIS
        This build task updates the changelog with the release and creates a PR
        to merge.

    .PARAMETER ProjectPath
        The root path to the project. Defaults to $BuildRoot.

    .PARAMETER OutputDirectory
        The base directory of all output. Defaults to folder 'output' relative to
        the $BuildRoot.

    .PARAMETER BuiltModuleSubdirectory
        The parent path of the module to be built.

    .PARAMETER VersionedOutputDirectory
        If the module should be built using a version folder, e.g. ./MyModule/1.0.0.
        Defaults to $true.

    .PARAMETER ProjectName
        The project name.

    .PARAMETER SourcePath
        The path to the source folder.

    .PARAMETER MainGitBranch
        The name of the default branch. Defaults to 'main'. It is used to compare
        and target the PR against.

    .PARAMETER BasicAuthPAT
        The personal access token to use to access the Azure DevOps Git repository
        to create the PR.

    .PARAMETER UseDefaultCredentials
        Use 'DefaultCredential'(Windows-Authentication) to access the Azure DevOps
        Git repository to create the PR. Use this for DevOps OnPrem deployments.
        The PAT is not required with this authentication methode.

    .PARAMETER PullRequestConfigBranchName
        The name of the branch to base the PR from (source branch). Defaults to
        'updateChangelogAfterv{0}'.

    .PARAMETER PullRequestConfigInstance
        The name of the Azure DevOps instance to use, where the PR should be created.

    .PARAMETER PullRequestConfigCollection
        The name of the Azure DevOps collection to use, where the PR should be created.

    .PARAMETER PullRequestConfigProject
        The name of the Azure DevOps project to use, where the PR should be created.

    .PARAMETER PullRequestConfigRepositoryID
        The name of the Azure DevOps repository to use, where the PR should be created.

    .PARAMETER PullRequestConfigDebug
        When set to $true will output the response from the Rest API call.

    .PARAMETER PullRequestConfigTitle
        The title of the PR. Defaults to 'Updating Changelog since release of v{0} +semver:skip'.

    .PARAMETER PullRequestConfigDescription
        The description of the PR. Defaults to 'Updating Changelog since release of v{0} +semver:skip'.

    .PARAMETER BuildInfo
        The build info object from ModuleBuilder. Defaults to an empty hashtable.

    .NOTES
        This is a build task that is primarily meant to be run by Invoke-Build but
        wrapped by the Sampler project's build.ps1 (https://github.com/gaelcolas/Sampler).
#>
param
(
    [Parameter()]
    [System.String]
    $ProjectPath = (property ProjectPath $BuildRoot),

    [Parameter()]
    [System.String]
    $OutputDirectory = (property OutputDirectory (Join-Path $BuildRoot 'output')),

    [Parameter()]
    [System.String]
    $BuiltModuleSubdirectory = (property BuiltModuleSubdirectory ''),

    [Parameter()]
    [System.Management.Automation.SwitchParameter]
    $VersionedOutputDirectory = (property VersionedOutputDirectory $true),

    [Parameter()]
    [System.String]
    $ProjectName = (property ProjectName ''),

    [Parameter()]
    [System.String]
    $SourcePath = (property SourcePath ''),

    [Parameter()]
    [System.String]
    $MainGitBranch = (property MainGitBranch 'main'),

    [Parameter()]
    [System.String]
    $BasicAuthPAT = (property BasicAuthPAT ''),

    [Parameter()]
    [System.String]
    $UseDefaultCredentials = (property UseDefaultCredentials $false),

    [Parameter()]
    [System.String]
    $PullRequestConfigBranchName = (property PullRequestConfigBranchName 'updateChangelogAfterv{0}'),

    [Parameter()]
    [System.String]
    $PullRequestConfigInstance = (property PullRequestConfigInstance ''),

    [Parameter()]
    [System.String]
    $PullRequestConfigCollection = (property PullRequestConfigCollection ''),

    [Parameter()]
    [System.String]
    $PullRequestConfigProject = (property PullRequestConfigProject ''),

    [Parameter()]
    [System.String]
    $PullRequestConfigRepositoryID = (property PullRequestConfigRepositoryID ''),

    [Parameter()]
    [System.String]
    $PullRequestConfigTitle = (property PullRequestConfigTitle 'Updating Changelog since release of v{0} +semver:skip'),

    [Parameter()]
    [System.String]
    $PullRequestConfigDescription = (property PullRequestConfigDescription 'Updating Changelog since release of v{0} +semver:skip'),

    [Parameter()]
    [System.String]
    $PullRequestConfigDebug = (property PullRequestConfigDebug $false),

    [Parameter()]
    $BuildInfo = (property BuildInfo @{ })
)

# Synopsis: Creates a PR to update the changelog with the released version
task Create_PR_From_SourceBranch {
    . Set-SamplerTaskVariable

    $BranchName = $PullRequestConfigBranchName -f $ModuleVersion

    Write-Build DarkGray ('About to create a PR based on the branch ''{0}''.' -f $BranchName)

    Write-Build DarkGray ("`tVerifying that the branch '{0}' exist." -f $BranchName)

    # This should not use Invoke-SamplerGit as this should not throw if fails.
    if ($UseDefaultCredentials -eq $true)
    {
        Write-Build DarkGray ("`tusing defaultCredentails for authentication.")
        <# We need to configure the pipeline step with
           - checkout: self
             submodules: true
             persistCredentials: true
          for this to work
          Cached credential will be removed during cleanup of the task.
        #>
        $upstreamChangelogBranch = git -c http.sslbackend=schannel ls-remote --heads origin $BranchName
    }
    elseif (-not ([System.String]::IsNullOrEmpty($BasicAuthPAT)))
    {
        Write-Build DarkGray ("`tusing PAT for authentication.")
        $base64pat = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(('{0}:{1}' -f 'PAT', $BasicAuthPAT)))
        $upstreamChangelogBranch = git -c http.sslbackend=schannel -c http.extraHeader="Authorization: Basic $base64pat" ls-remote --heads origin $BranchName
    }
    else
    {
        throw 'Must use defaultCedentials or provide a personal access token to create a pull request.'
    }

    if ($upstreamChangelogBranch)
    {
        Write-Build DarkGray ("`tBranch '{0}' exist." -f $BranchName)

        foreach ($gitConfigKey in @('BranchName', 'Instance', 'Collection', 'Project', 'RepositoryID', 'Debug', 'Title', 'Description'))
        {
            $gitConfigVariableName = 'PullRequestConfig{0}' -f $gitConfigKey

            $configurationValue = Get-Variable -Name $gitConfigVariableName -ValueOnly -ErrorAction 'SilentlyContinue'

            <#
                Using values in the following order:

                1. Set in build configuration
                2. Parameter, environment variable, passed from parent scope, or default value.
            #>
            if ($BuildInfo.PullRequestConfig -and $BuildInfo.PullRequestConfig.($gitConfigKey))
            {
                # Override the value that was set prior to the one in the build configuration.
                $configurationValue = $BuildInfo.PullRequestConfig.($gitConfigKey)

                Write-Build DarkGray "`t`t$gitConfigVariableName was set in build configuration with the value '$configurationValue'"

                Set-Variable -Name $gitConfigVariableName -Value $configurationValue
            }
            elseif ($configurationValue)
            {
                Write-Build DarkGray "`t`t$gitConfigVariableName was set to the the value '$configurationValue' from parameter, environment variable, passed from parent scope, or was the default value."
            }
        }

        Write-Build DarkGray "`tCreating PR based on the branch."

        if ([System.String]::IsNullOrEmpty($PullRequestConfigRepositoryID))
        {
            $PullRequestConfigRepositoryID = $ProjectName
        }

        $payload = @{
            sourceRefName = "refs/heads/$BranchName"
            targetRefName = "refs/heads/$MainGitBranch"
            title = $PullRequestConfigTitle -f $ModuleVersion
            description = $PullRequestConfigDescription -f $ModuleVersion
            completionOptions = @{
                deleteSourceBranch = $true
            }
        }

        $uri = 'https://{0}/{1}/{2}/_apis/git/repositories/{3}/pullrequests?supportsIterations=false&api-version=6.0' -f @(
            $PullRequestConfigInstance,
            $PullRequestConfigCollection,
            $PullRequestConfigProject,
            $PullRequestConfigRepositoryID
        )

        $invokeRestMethodParameters = @{
            Method      = 'POST'
            Uri         = $uri
            ContentType = 'application/json; charset=utf-8'
            Body        = $payload | ConvertTo-Json
            ErrorAction = 'Stop'
        }

        if ($UseDefaultCredentials -eq $true)
        {
            <#
                The 'Defaultcredential'(Project Collection Build Service Accounts) need
                the 'Contribute to pull requests' permission for the repositories.
            #>
            $invokeRestMethodParameters.UseDefaultCredentials = $true
        }
        else
        {
            $invokeRestMethodParameters.Headers= @{
                AUTHORIZATION = 'basic {0}' -f $base64pat
            }
        }
        
        $result = Invoke-RestMethod @invokeRestMethodParameters

        if ($PullRequestConfigDebug)
        {
            $result
        }

        Write-Build Green ('Opened a PR for the branch ''{0}''.' -f $BranchName)
    }
    else
    {
        Write-Build Yellow 'No branch was found. Nothing to do, exiting.'
    }
}
