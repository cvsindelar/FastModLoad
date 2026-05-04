# FastModLoad ('fml'): Fast Module Loader for Lmod-Based HPC Software Stacks

FastModLoad is a 'helper' module that coordinates with Lmod to greatly accelerate slow module loads. It works by caching flattened modulefiles whose other module dependencies are eliminated. FastModLoad reduces loading times to below 3 seconds for all applications installed on our Yale HPC clusters, demonstrating up to 30-fold speed improvement. For reliability and consistency, caches are checked with every load to detect module system file updates or other environment changes. Due to its straightforward bash implementation, minimal dependence on the system environment, and flexibility, FastModLoad could prove useful in a variety of HPC environments.

## Installation

For EasyBuild users, an easyconfig 'eb' file is provided. If you are not using EasyBuild (untested currently), edit the 'fml/1.0.lua' file to taste, and place in the desired location in your module tree; be sure that your edited luafile correctly specifies the location of 'fml.sh'.

# Usage

```
ml fml        # Activates fast module loading
module [...]  # Augmented Lmod module function:
              #    Dectects and loads available 'fast' modules in place ofthe original 'slow' Lmod ones
              #    Modified 'module list' function for fast modules
fml [...]     # Toggles between:
              #   (1) Building/loading a fast module for the current environment
              #   (2) Unpacking a loaded fast module back to the original Lmod environment
```

