# Build stage: restore and publish the C# app
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY src/FormDojo/FormDojo.csproj src/FormDojo/
RUN dotnet restore src/FormDojo/FormDojo.csproj
COPY src/FormDojo/ src/FormDojo/
RUN dotnet publish src/FormDojo/FormDojo.csproj -c Release -o /app/publish --no-restore

# Run stage: small ASP.NET runtime image
FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /app/publish .
# The site files are copied last, so changing them rebuilds only this layer.
COPY site/ site/

ENV ASPNETCORE_URLS=http://+:8080 \
    SITE_DIR=/app/site
EXPOSE 8080
USER $APP_UID
ENTRYPOINT ["dotnet", "FormDojo.dll"]
