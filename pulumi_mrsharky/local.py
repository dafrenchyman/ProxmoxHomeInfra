import os


class Local:

    @staticmethod
    def text_to_file(text: str, filename) -> None:
        if os.path.isfile(filename):
            os.remove(filename)
        with open(filename, "w", 0o600) as file:
            file.write(text)
            os.chmod(filename, 0o600)
        return
