using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using Azure;
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

// A page that lists every saved submission, newest first.
app.MapGet("/submissions", async () =>
{
    var rows = new List<TableEntity>();

    try
    {
        // Show at most 500 rows to keep the page small.
        await foreach (var row in tableClient.QueryAsync<TableEntity>())
        {
            rows.Add(row);
            if (rows.Count >= 500)
            {
                break;
            }
        }
    }
    catch (RequestFailedException ex) when (ex.Status == 404)
    {
        // The table does not exist until the first submission is saved.
    }
    catch (Exception ex)
    {
        app.Logger.LogError(ex, "Could not read the submissions");
        return Results.Problem("Could not read the submissions. Please try again later.");
    }

    rows = rows.OrderByDescending(row => row.Timestamp).ToList();

    // One column per field name, in the order they are first seen.
    var columns = new List<string>();
    foreach (var row in rows)
    {
        foreach (var key in row.Keys)
        {
            if (key is "PartitionKey" or "RowKey" or "Timestamp" or "odata.etag" || columns.Contains(key))
            {
                continue;
            }

            columns.Add(key);
        }
    }

    // Values come from visitors, so they are always HTML-encoded.
    string Encode(object? value) => WebUtility.HtmlEncode(value?.ToString() ?? "");

    // The list is public, so email addresses are shortened: "ada@example.com" -> "ad***@example.com".
    string ShortenEmail(string email)
    {
        var at = email.IndexOf('@');
        var local = at < 0 ? email : email[..at];
        var domain = at < 0 ? "" : email[at..];
        return (local.Length > 2 ? local[..2] : local[..Math.Min(1, local.Length)]) + "***" + domain;
    }

    var html = new StringBuilder();
    html.AppendLine("<!DOCTYPE html>");
    html.AppendLine("<html lang=\"en\">");
    html.AppendLine("  <head>");
    html.AppendLine("    <meta charset=\"UTF-8\" />");
    html.AppendLine("    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />");
    html.AppendLine("    <title>Saved orders</title>");
    html.AppendLine("    <link rel=\"stylesheet\" href=\"styles.css\" />");
    html.AppendLine("  </head>");
    html.AppendLine("  <body>");
    html.AppendLine("    <header>");
    html.AppendLine("      <h1>Saved orders</h1>");
    html.AppendLine("    </header>");
    html.AppendLine("    <main>");

    if (rows.Count == 0)
    {
        html.AppendLine("      <p>No orders have been saved yet.</p>");
    }
    else
    {
        html.AppendLine($"      <p>{rows.Count} saved order(s), newest first.</p>");
        html.AppendLine("      <table>");
        html.AppendLine("        <thead>");
        html.AppendLine("          <tr>");
        html.AppendLine("            <th scope=\"col\">Saved at (UTC)</th>");
        foreach (var column in columns)
        {
            html.AppendLine($"            <th scope=\"col\">{Encode(column)}</th>");
        }
        html.AppendLine("          </tr>");
        html.AppendLine("        </thead>");
        html.AppendLine("        <tbody>");
        foreach (var row in rows)
        {
            html.AppendLine("          <tr>");
            html.AppendLine($"            <td>{Encode(row.Timestamp?.UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss"))}</td>");
            foreach (var column in columns)
            {
                var text = row.TryGetValue(column, out var value) ? value?.ToString() ?? "" : "";
                if (text.Length > 0 && column.Contains("email", StringComparison.OrdinalIgnoreCase))
                {
                    text = ShortenEmail(text);
                }

                html.AppendLine($"            <td>{Encode(text)}</td>");
            }
            html.AppendLine("          </tr>");
        }
        html.AppendLine("        </tbody>");
        html.AppendLine("      </table>");
    }

    html.AppendLine("      <p><a href=\"/\">Back to the order form</a></p>");
    html.AppendLine("    </main>");
    html.AppendLine("    <footer>");
    html.AppendLine("      <p>form-dojo</p>");
    html.AppendLine("    </footer>");
    html.AppendLine("  </body>");
    html.AppendLine("</html>");

    return Results.Content(html.ToString(), "text/html; charset=utf-8");
});

app.Run();
