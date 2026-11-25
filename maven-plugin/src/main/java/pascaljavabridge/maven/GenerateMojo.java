package pascaljavabridge.maven;

import java.io.File;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

import org.apache.maven.plugin.AbstractMojo;
import org.apache.maven.plugin.MojoExecutionException;
import org.apache.maven.plugins.annotations.LifecyclePhase;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;
import org.apache.maven.plugins.annotations.ResolutionScope;
import org.apache.maven.project.MavenProject;

import pascaljavabridge.BindingGenerator;

/**
 * Generates an Object Pascal unit with wrappers for Java classes of this project and its
 * dependencies. Runs after compilation, so the project's own classes can be wrapped.
 *
 * <pre>{@code
 * <plugin>
 *   <groupId>io.github.maartenkroon</groupId>
 *   <artifactId>pascal-java-bridge-maven-plugin</artifactId>
 *   <version>...</version>
 *   <executions>
 *     <execution>
 *       <goals><goal>generate</goal></goals>
 *       <configuration>
 *         <unit>MyJava</unit>
 *         <includes><include>com.example.**</include></includes>
 *       </configuration>
 *     </execution>
 *   </executions>
 * </plugin>
 * }</pre>
 */
@Mojo(name = "generate", defaultPhase = LifecyclePhase.PROCESS_CLASSES, threadSafe = true,
        requiresDependencyResolution = ResolutionScope.RUNTIME)
public class GenerateMojo extends AbstractMojo {

    /** Name of the generated Pascal unit (and of the .pas file). */
    @Parameter(property = "pascal.unit", required = true)
    private String unit;

    /**
     * Classes to wrap: class names (java.util.ArrayList, java.util.Map$Entry) or wildcard
     * patterns: {@code com.example.*} (one package), {@code com.example.**} (with subpackages),
     * {@code com.example.*Service} ('*' within one name segment, '**' across packages).
     */
    @Parameter(required = true)
    private List<String> includes;

    /** Patterns of classes to leave out (same syntax as includes). */
    @Parameter
    private List<String> excludes;

    /** Also wrap the public types referenced by the selected classes, this many levels deep. */
    @Parameter(property = "pascal.depth", defaultValue = "0")
    private int depth;

    /** Directory the unit is written to. */
    @Parameter(property = "pascal.outputDirectory",
            defaultValue = "${project.build.directory}/generated-sources/pascal")
    private File outputDirectory;

    /** Also write the Pascal runtime (JavaBridge.pas, JavaBridgeHandler.inc) to the output directory. */
    @Parameter(property = "pascal.withRuntime", defaultValue = "true")
    private boolean withRuntime;

    /** Skip this goal. */
    @Parameter(property = "pascal.skip", defaultValue = "false")
    private boolean skip;

    @Parameter(defaultValue = "${project}", readonly = true, required = true)
    private MavenProject project;

    @Override
    public void execute() throws MojoExecutionException {
        if (skip) {
            getLog().info("Skipping Pascal wrapper generation");
            return;
        }
        BindingGenerator.Options o = new BindingGenerator.Options();
        o.unit = unit;
        o.outputDirectory = outputDirectory.toPath();
        o.includes = new ArrayList<>(includes);
        if (excludes != null) o.excludes = new ArrayList<>(excludes);
        o.depth = depth;
        o.withRuntime = withRuntime;
        o.info = getLog()::info;
        o.warn = getLog()::warn;
        try {
            // project classes + runtime dependencies (target/classes comes first)
            for (String e : project.getRuntimeClasspathElements()) {
                Path p = Path.of(e);
                if (p.toFile().exists()) o.classpath.add(p);
            }
            BindingGenerator.generate(o);
        } catch (Exception e) {
            throw new MojoExecutionException("Pascal wrapper generation failed: " + e.getMessage(), e);
        }
    }
}
