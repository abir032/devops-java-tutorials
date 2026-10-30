# ---- Stage 1: build the jar with Maven + JDK 21 ----
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /build

# Dependencies first: this layer stays cached until pom.xml changes.
COPY pom.xml .
RUN mvn -q dependency:go-offline

COPY src ./src
RUN mvn -q package -DskipTests

# ---- Stage 2: small runtime image with only a JRE ----
FROM eclipse-temurin:21-jre
WORKDIR /app

RUN useradd --create-home appuser
USER appuser

COPY --from=build /build/target/*.jar app.jar

EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
