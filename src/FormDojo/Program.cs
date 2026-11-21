using System.Text.RegularExpressions;
using Azure.Data.Tables;

// The folder with index.html and styles.css (the files students edit).
var siteDir = Path.GetFullPath(Environment.GetEnvironmentVariable("SITE_DIR") ?? "site");

var builder = WebApplication.CreateBuilder(new WebApplicationOptions
{
    Args = args,
    WebRootPath = siteDir,
});

// Azurite (local storage emulator) is the default for local development.
var connectionString =
    Environment.GetEnvironmentVariable("STORAGE_CONNECTION_STRING") ?? "UseDevelopmentStorage=true";
var tableClient = new TableClient(connectionString, "submissions");

var app = builder.Build();

app.UseDefaultFiles();
app.UseStaticFiles();

// Table Storage property names must look like C# identifiers.
var validFieldName = new Regex("^[A-Za-z_][A-Za-z0-9_]{0,63}$");
var reservedNames = new HashSet<string> { "PartitionKey", "RowKey", "Timestamp", "ETag" };

app.MapPost("/submit", async (HttpContext context) =>
{
    if (!context.Request.HasFormContentType)
    {
        return Results.BadRequest("Send the data as a form.");
    }

    var form = await context.Request.ReadFormAsync();

    var entity = new TableEntity("submissions", Guid.NewGuid().ToString());

    // Save every field the form sends, so students can add fields freely.
    foreach (var field in form)
    {
        if (!validFieldName.IsMatch(field.Key) || reservedNames.Contains(field.Key))
        {
            continue;
        }

        var value = field.Value.ToString();
        entity[field.Key] = value.Length > 1000 ? value[..1000] : value;
    }

    try
    {
        await tableClient.CreateIfNotExistsAsync();
        await tableClient.AddEntityAsync(entity);
    }
    catch (Exception ex)
    {
        app.Logger.LogError(ex, "Could not save the submission");
        return Results.Problem("Could not save your submission. Please try again later.");
    }

    return Results.Redirect("/thanks.html", permanent: false);
});

app.Run();
